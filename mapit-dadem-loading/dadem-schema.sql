--
-- mapit-schema.sql:
-- Schema for the DaDem Postgres database.
--
-- Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
-- Email: francis@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: dadem-schema.sql,v 1.3 2004-12-13 12:41:28 chris Exp $
--

-- data about each democratic reperesentative
create table representative (
    id serial not null primary key,
    area_id integer not null,
    area_type char(3) not null,
    name text not null,
    party text not null,
    -- 0: either, 1: fax, 2: email, 3: shame (i.e. refuses to be contacted)
    method integer not null check (method = 0 or method = 1 or method = 2),
    email text,
    fax text
);
create index representative_area_id_idx on representative(area_id);

