from dataclasses import dataclass, field


@dataclass(frozen=True)
class DataScope:
    """保留旧接口兼容；方案A不再用行政范围配置过滤社区/街道/民政数据。"""
    communities: frozenset[str] = frozenset()
    org_ids: frozenset[int] = frozenset()
    district_codes: frozenset[str] = frozenset()

    def __post_init__(self):
        for name in ("communities", "org_ids", "district_codes"):
            object.__setattr__(self, name, frozenset(getattr(self, name)))


@dataclass(frozen=True)
class Principal:
    user_id: int
    username: str
    role_code: str
    org_id: int | None = None
    elder_id: int | None = None
    caregiver_id: int | None = None
    scope: DataScope = field(default_factory=DataScope)
    auth_version: str | None = None
    audit_org: str | None = None
