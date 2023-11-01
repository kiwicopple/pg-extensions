\echo Use "CREATE EXTENSION countries" to load this file. \quit
alter table countries drop column id;
alter table countries add primary key (iso3);