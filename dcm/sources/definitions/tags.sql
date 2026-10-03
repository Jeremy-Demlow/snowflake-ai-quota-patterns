DEFINE TAG {{ control_database }}.{{ control_schema }}.AI_ELIGIBILITY
    ALLOWED_VALUES 'approved', 'ineligible'
    COMMENT = 'IAM-maintained eligibility metadata; not an authorization DENY policy';

DEFINE TAG {{ control_database }}.{{ control_schema }}.AI_SPEND_TIER
    ALLOWED_VALUES {% for tier in spend_tiers %}'{{ tier | replace("'", "''") }}'{% if not loop.last %}, {% endif %}{% endfor %}
    COMMENT = 'Native quota selection; no model or feature permission';

DEFINE TAG {{ control_database }}.{{ control_schema }}.AI_COST_CENTER
    ALLOWED_VALUES {% for cost_center in cost_centers %}'{{ cost_center | replace("'", "''") }}'{% if not loop.last %}, {% endif %}{% endfor %}
    COMMENT = 'Finance-approved funding owner; current-tag reporting can restate history';