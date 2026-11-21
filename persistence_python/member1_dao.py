"""成员1：档案、评估、照护计划及总览。"""
from .base_dao import BaseDAO
from .procedures import call_procedure


class Member1DAO:
    organizations = BaseDAO("service_org")
    elders = BaseDAO("elder_profile")
    assessments = BaseDAO("ability_assessment")
    plans = BaseDAO("care_plan")
    plan_items = BaseDAO("care_plan_item")

    def overview(self, session, actor, elder_id):
        self.elders.required(session, elder_id, actor)
        return call_procedure(session, "usp_GetElderCareOverview", elder_id=elder_id).result_sets
