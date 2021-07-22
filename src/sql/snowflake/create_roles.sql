!SET variable_substitution=true;
use role securityadmin;

create user if not exists mysql_rep identified  by '&{PASS}';
grant role r_mysql_rep to user mysql_rep;
grant role r_mysql_rep to role accountadmin;
grant role r_mysql_rep to role sysadmin;
alter user mysql_rep set DEFAULT_WAREHOUSE=wh_ingest;
alter user mysql_rep set DEFAULT_NAMESPACE=mysql_ingest.landing;
alter user mysql_rep set default_role=r_mysql_rep;