"""按成员4角色矩阵授权；系统管理员业务只读，账号管理单独授权。"""
ROLES = frozenset({"COMMUNITY_ADMIN", "ELDER", "FAMILY", "CAREGIVER", "ORG_MANAGER",
                   "STREET_SUPERVISOR", "CIVIL_SUPERVISOR", "SYS_ADMIN"})
REGIONAL_ROLES = frozenset({"COMMUNITY_ADMIN", "STREET_SUPERVISOR", "CIVIL_SUPERVISOR"})
PUBLIC_READ = {"service_item", "subsidy_policy"}
ELDER_READ = {"elder_profile", "ability_assessment", "care_plan", "care_plan_item",
              "service_order", "dispatch_record", "monitor_device", "vital_sign",
              "emergency_event", "subsidy_application", "subsidy_application_item"}
STAFF_READ = ELDER_READ | {"service_org", "caregiver", "caregiver_certificate",
                           "caregiver_schedule", "work_record", "quality_inspection",
                           "rectification", "subsidy_audit_log"}
READ = {
    "ELDER": ELDER_READ, "FAMILY": ELDER_READ,
    "CAREGIVER": {"elder_profile", "care_plan", "care_plan_item", "service_order",
                  "dispatch_record", "caregiver", "caregiver_certificate", "caregiver_schedule",
                  "work_record", "emergency_event", "monitor_device", "vital_sign", "rectification"},
    "ORG_MANAGER": STAFF_READ,
    "COMMUNITY_ADMIN": STAFF_READ,
    "STREET_SUPERVISOR": STAFF_READ, "CIVIL_SUPERVISOR": STAFF_READ,
}
WRITE = {
    "COMMUNITY_ADMIN": {"elder_profile", "ability_assessment", "care_plan", "care_plan_item",
                        "service_item", "monitor_device", "vital_sign"},
    "ORG_MANAGER": {"caregiver", "caregiver_certificate", "caregiver_schedule"},
    "CAREGIVER": {"vital_sign"},
    "CIVIL_SUPERVISOR": {"quality_inspection"},
    "SYS_ADMIN": {"sys_user"},
}
BUSINESS = {
    "order:create": {"ELDER", "FAMILY", "COMMUNITY_ADMIN"},
    "order:dispatch": {"COMMUNITY_ADMIN"}, "order:reassign": {"COMMUNITY_ADMIN"},
    "order:accept": {"CAREGIVER"}, "order:reject": {"CAREGIVER"},
    "order:start": {"CAREGIVER"}, "order:complete": {"CAREGIVER", "COMMUNITY_ADMIN"},
    "order:withdraw": {"COMMUNITY_ADMIN"}, "order:cancel": {"ELDER", "FAMILY", "COMMUNITY_ADMIN"},
    "work:checkin": {"CAREGIVER"}, "work:checkout": {"CAREGIVER"}, "work:review": {"ORG_MANAGER"},
    "emergency:raise": {"ELDER", "FAMILY", "CAREGIVER", "COMMUNITY_ADMIN"},
    "emergency:accept": {"CAREGIVER", "ORG_MANAGER", "COMMUNITY_ADMIN"},
    "emergency:close": {"CAREGIVER", "ORG_MANAGER", "COMMUNITY_ADMIN"},
    "subsidy:create": {"COMMUNITY_ADMIN"},
    "subsidy:details": {"COMMUNITY_ADMIN"},
    "subsidy:audit": {"COMMUNITY_ADMIN", "STREET_SUPERVISOR"},
    "subsidy:community_audit": {"COMMUNITY_ADMIN"},
    "subsidy:street_audit": {"STREET_SUPERVISOR"},
    "subsidy:assign": {"COMMUNITY_ADMIN", "STREET_SUPERVISOR"},  # 入口在行锁内继续校验节点。
    "subsidy:pay": set(),
    "rectification:create": set(),
    "rectification:submit": {"ORG_MANAGER"},
    "rectification:review": {"STREET_SUPERVISOR"},
    "account:manage": {"SYS_ADMIN"},
    "account:password": set(ROLES),
}
