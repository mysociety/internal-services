--
-- mapit-schema.sql:
-- Schema for the MaPit Postgres database.
--
-- Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: mapit-schema.sql,v 1.4 2004-11-29 12:57:54 chris Exp $
--

-- description of areas
create table area (
    id serial not null primary key,
    parent_area_id integer references area(id),
    unit_id integer,        -- ESRI shapefile unit ID
    ons_code varchar(6),    -- six-digit ward code
    type char(3) not null,  -- 'CTY' or whatever
    -- Country in which this area lies.
    -- 'E'  England
    -- 'N'  Northern Ireland
    -- 'S'  Scotland
    -- 'W'  Wales
    country char(1)
);

-- different names of areas
create table area_name (
    area_id integer references area(id),
    -- Which type of name this is.
    -- 'O'  name used by Ordnance Survey
    -- 'S'           ... ONS
    -- 'G'           ... GovEval
    -- 'F'  "friendly" name for our own use
    name_type char(1) not null check (name_type = 'O' or name_type = 'S' or name_type = 'G' or name_type = 'F'),
    name text not null,
    primary key (area_id, name_type)
);

create index area_name_area_id_idx on area_name(area_id);

-- lookup table for postcodes
create table postcode (
    id serial not null primary key,
    postcode varchar(8) not null,
    easting real not null,
    northing real not null
);

create unique index postcode_postcode_idx on postcode(postcode);

-- mapping from postcodes to areas
create table postcode_area (
    postcode_id integer not null references postcode(id),
    area_id integer not null
);

create index postcode_area_postcode_id_idx on postcode_area(postcode_id);
