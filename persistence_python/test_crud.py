import pytest
from sqlalchemy import select

from .base_dao import BaseDAO
from .errors import AccessDenied
from .member1_dao import Member1DAO
from .models import ElderProfile
from .permissions import DataScope, Principal


def test_scoped_pk_page_and_identity_cache(session, fixture):
    f = fixture
    dao = Member1DAO().elders
    # 系统管理员先加载另一社区对象，随后普通账号主键查询仍不得命中identity-map缓存。
    other = dao.required(session, f["elders"][1].elder_id, f["actors"]["SYS_ADMIN"])
    for role in ("ELDER", "FAMILY"):
        actor = f["actors"][role]
        assert dao.get(session, other.elder_id, actor) is None
        rows = dao.page(session, actor, size=1)
        assert rows[0].elder_id == f["elders"][0].elder_id


def test_scheme_a_preserves_authorized_read_without_region_configuration(session, fixture):
    f = fixture
    actor = Principal(f["actors"]["CIVIL_SUPERVISOR"].user_id, "civil", "CIVIL_SUPERVISOR")
    ids = {obj.elder_id for obj in Member1DAO().elders.get_all(session, actor)}
    assert {obj.elder_id for obj in f["elders"]} <= ids


def test_caregiver_cannot_see_unassigned_elder(session, fixture):
    assert Member1DAO().elders.get(session, fixture["elders"][0].elder_id,
                                 fixture["actors"]["CAREGIVER"]) is None


def test_scoped_crud_and_batch(session, fixture):
    f = fixture
    dao, actor = Member1DAO().elders, f["actors"]["COMMUNITY_ADMIN"]
    from uuid import uuid4

    def values(name, community="测试社区1"):
        return dict(elder_name=name, id_card_no=f"{uuid4().int % 10**18:018d}",
                    birth_date=f["elders"][0].birth_date, address="测试地址", community_name=community)

    obj = dao.add(session, values("新增测试"), actor)
    pk = obj.elder_id
    dao.update(session, pk, actor, address="更新测试")
    assert dao.required(session, pk, actor).address == "更新测试"
    dao.update(session, pk, actor, community_name="测试社区2")
    assert dao.required(session, pk, actor).community_name == "测试社区2"
    with pytest.raises(ValueError):
        dao.batch_add(session, [values("可见"), {**values("非法"), "unknown_column": 1}], actor)
    assert session.scalar(select(ElderProfile.elder_id).where(ElderProfile.elder_name == "可见")) is None
    rows = dao.batch_add(session, [values("批量A"), values("批量B")], actor)
    assert len(rows) == 2
    dao.delete(session, pk, actor)
    assert dao.get(session, pk, actor) is None


def test_family_uses_actual_sys_user_binding(session, fixture):
    from dataclasses import replace
    f = fixture
    actor = f["actors"]["FAMILY"]
    forged = replace(actor, elder_id=f["elders"][1].elder_id)
    dao = Member1DAO().elders
    assert dao.get(session, f["elders"][0].elder_id, actor) is not None
    assert dao.get(session, f["elders"][1].elder_id, forged) is None


@pytest.mark.parametrize("role,binding", [("ELDER", "elder_id"), ("FAMILY", "elder_id"),
                                          ("CAREGIVER", "caregiver_id"), ("ORG_MANAGER", "org_id")])
def test_missing_personal_or_org_binding_never_expands_access(session, fixture, role, binding):
    from dataclasses import replace
    actor = replace(fixture["actors"][role], **{binding: None})
    with pytest.raises(AccessDenied):
        BaseDAO("service_item").page(session, actor)


def test_batch_add_update_and_filtered_query(session, fixture):
    from uuid import uuid4
    dao, actor = BaseDAO("service_item"), fixture["actors"]["COMMUNITY_ADMIN"]
    tag = "BATCH:" + uuid4().hex[:16]
    rows = dao.batch_add(session, (dict(service_name=tag+str(i), service_type="家政", price=1,
                                       duration=30, charge_unit="次") for i in range(3)), actor)
    assert len(rows) == 3
    dao.batch_update(session, [(row.service_id, {"price": 2+i}) for i, row in enumerate(rows)], actor)
    for i, row in enumerate(rows):
        result = dao.page(session, actor, filters={"service_name": tag+str(i)})
        assert len(result) == 1 and result[0].price == 2+i
    with pytest.raises(ValueError):
        dao.batch_update(session, [(rows[0].service_id, {"price": 99}),
                                   (rows[1].service_id, {"unknown_column": 1})], actor)
    assert dao.required(session, rows[0].service_id, actor).price == 2


def test_org_manager_cannot_access_other_org(session, fixture):
    f = fixture
    actor = f["actors"]["ORG_MANAGER"]
    dao = BaseDAO("caregiver")
    assert dao.get(session, f["caregivers"][1].caregiver_id, actor) is None
    with pytest.raises(AccessDenied):
        dao.update(session, f["caregivers"][0].caregiver_id, actor, org_id=f["orgs"][1].org_id)


def test_caregiver_order_scope_is_dispatch_not_all_orders_of_same_elder(session, fixture):
    from .member2_dao import Member2DAO
    from .test_business import create_order, dispatch_order
    f, dao = fixture, Member2DAO()
    # 同一社区的两家机构，避免正式派单规则先因服务区域不同拒绝夹具。
    f["caregivers"][1].service_area = f["caregivers"][0].service_area
    f["orgs"][1].service_area = f["orgs"][0].service_area
    session.flush()
    own, other = create_order(session, f), create_order(session, f)
    dispatch_order(session, f, own)
    dao.action(session, f["actors"]["COMMUNITY_ADMIN"], other, "DISPATCH", caregiver_id=f["caregivers"][1].caregiver_id)
    assert dao.orders.get(session, own, f["actors"]["CAREGIVER"]) is not None
    assert dao.orders.get(session, other, f["actors"]["CAREGIVER"]) is None
    assert dao.orders.get(session, other, f["actors"]["ORG_MANAGER"]) is None


def test_controlled_tables_and_admin_business_read_only(session, fixture):
    f = fixture
    with pytest.raises(AccessDenied):
        BaseDAO("service_order").add(session, {}, f["actors"]["COMMUNITY_ADMIN"])
    with pytest.raises(AccessDenied):
        BaseDAO("service_item").update(session, f["item"].service_id, f["actors"]["SYS_ADMIN"], price=1)


@pytest.mark.parametrize("page,size,sort", [(0, 10, None), (1, 201, None), (True, 10, None), (1, 10, "price; DROP TABLE dbo.service_item")])
def test_page_validation(session, fixture, page, size, sort):
    with pytest.raises(ValueError):
        BaseDAO("service_item").page(session, fixture["actors"]["ELDER"], page=page, size=size, order_by=sort)
