{% for role_suffix in ['PRODUCT_COCO', 'PRODUCT_SQL', 'MODEL_STANDARD', 'MODEL_OPUS', 'MODEL_WORKLOAD', 'EMPLOYEE_COCO', 'EMPLOYEE_SQL', 'PREMIUM_MODELS', 'SERVICE_SQL', 'QUOTA_OPERATOR', 'COST_AUDITOR'] %}
DEFINE ROLE {{ role_prefix }}_{{ role_suffix }};
{% endfor %}

GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER
    TO ROLE {{ role_prefix }}_PRODUCT_COCO;

GRANT DATABASE ROLE SNOWFLAKE.AI_FUNCTIONS_USER
    TO ROLE {{ role_prefix }}_PRODUCT_SQL;

GRANT USE AI FUNCTION AI_COMPLETE ON ACCOUNT
    TO ROLE {{ role_prefix }}_PRODUCT_SQL;

GRANT ROLE {{ role_prefix }}_PRODUCT_COCO
    TO ROLE {{ role_prefix }}_EMPLOYEE_COCO;
GRANT ROLE {{ role_prefix }}_MODEL_STANDARD
    TO ROLE {{ role_prefix }}_EMPLOYEE_COCO;

GRANT ROLE {{ role_prefix }}_PRODUCT_SQL
    TO ROLE {{ role_prefix }}_EMPLOYEE_SQL;
GRANT ROLE {{ role_prefix }}_MODEL_STANDARD
    TO ROLE {{ role_prefix }}_EMPLOYEE_SQL;

GRANT ROLE {{ role_prefix }}_MODEL_OPUS
    TO ROLE {{ role_prefix }}_PREMIUM_MODELS;

GRANT ROLE {{ role_prefix }}_PRODUCT_SQL
    TO ROLE {{ role_prefix }}_SERVICE_SQL;
GRANT ROLE {{ role_prefix }}_MODEL_WORKLOAD
    TO ROLE {{ role_prefix }}_SERVICE_SQL;

GRANT USAGE ON DATABASE {{ control_database }}
    TO ROLE {{ role_prefix }}_QUOTA_OPERATOR;
GRANT USAGE ON SCHEMA {{ control_database }}.{{ control_schema }}
    TO ROLE {{ role_prefix }}_QUOTA_OPERATOR;

GRANT USAGE ON DATABASE {{ control_database }}
    TO ROLE {{ role_prefix }}_COST_AUDITOR;
GRANT USAGE ON SCHEMA {{ control_database }}.{{ control_schema }}
    TO ROLE {{ role_prefix }}_COST_AUDITOR;

GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER
    TO ROLE {{ role_prefix }}_COST_AUDITOR;
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER
    TO ROLE {{ role_prefix }}_COST_AUDITOR;

GRANT APPLYBUDGET ON TAG {{ control_database }}.{{ control_schema }}.AI_ELIGIBILITY
    TO ROLE {{ quota_creator_role }};
GRANT APPLYBUDGET ON TAG {{ control_database }}.{{ control_schema }}.AI_SPEND_TIER
    TO ROLE {{ quota_creator_role }};