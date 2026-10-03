{% for model_role in standard_model_roles %}
GRANT APPLICATION ROLE SNOWFLAKE."{{ model_role | replace('"', '""') }}"
    TO ROLE {{ role_prefix }}_MODEL_STANDARD;
{% endfor %}

{% for model_role in premium_model_roles %}
GRANT APPLICATION ROLE SNOWFLAKE."{{ model_role | replace('"', '""') }}"
    TO ROLE {{ role_prefix }}_MODEL_OPUS;
{% endfor %}

{% for model_role in workload_model_roles %}
GRANT APPLICATION ROLE SNOWFLAKE."{{ model_role | replace('"', '""') }}"
    TO ROLE {{ role_prefix }}_MODEL_WORKLOAD;
{% endfor %}