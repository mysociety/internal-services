--
-- mapit-schema.sql:
-- Schema for the MaPit Postgres database.
--
-- Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: mapit-schema.sql,v 1.20 2006-08-23 00:34:56 francis Exp $
--

-- generations, for currency of data
create table generation (
    id serial not null primary key,
    active boolean not null default (false),
    created integer not null
);

-- views for the "current" generation, i.e. the data which should be returned
-- to users; and the "new" generation, i.e. the data which are being built
create view current_generation as 
    select id from generation 
    where active 
    order by id desc limit 1;
create view new_generation as 
    select id from generation 
    where not active and id >= (select last_value from generation_id_seq);

-- description of areas
create table area (
    id serial not null primary key,
    parent_area_id integer references area(id),
    unit_id integer,        -- ESRI shapefile unit ID (really admin area ID)
    ons_code varchar(7),    -- 6+-digit ward code
    geom_hash char(40),     -- SHA1 hash of geometry (see process_boundary_line). Now obsolete.
    type char(3) not null,  -- 'CTY' or whatever
    -- Country in which this area lies.
    -- 'E'  England
    -- 'N'  Northern Ireland
    -- 'S'  Scotland
    -- 'W'  Wales
    -- Strictly, of course, Northern Ireland is not a country. So sue me. A
    -- null value for country means "not yet known"; this is necessary because
    -- in GB we can only determine country by searching for overlapping areas
    -- such as EUR regions.
    country char(1) check (country is null or country = 'E' or country = 'N' or country = 'S' or country = 'W'),
    -- Generation numbers. This area is current for generations of the database
    -- >= the smallest generation number, and <= the highest generation number.
    -- If on loading new data we identify an area which matches the type and
    -- either the ONS code or geometry hash of an old area, we re-use the old
    -- area ID and update the highest generation number to include the new
    -- generation.
    generation_low integer not null,
    generation_high integer not null
);

-- index these so that updates may be made.
--create unique index area_unit_id_idx on area(unit_id);
create unique index area_ons_code_idx on area(ons_code);
-- NB these are not unique, because two areas may be coterminous
create index area_geom_hash_idx on area(geom_hash);

-- different names of areas
create table area_name (
    area_id integer references area(id),
    -- Which type of name this is.
    name_type char(1) not null check (
            name_type = 'O' or -- name used by Ordnance Survey
            name_type = 'S' or --          ... ONS
            name_type = 'M' or --          ... mySociety
            name_type = 'G' or --          ... GovEval
            name_type = 'X' or --          ... FaxYourMP / PublicWhip
            name_type = 'L' or --          ... legislation
            name_type = 'F' or -- "friendly" name for our own use
            name_type = 'C'    -- "canonical" name for name matching
        ),
    name text not null,
    primary key (area_id, name_type)
);

create index area_name_area_id_idx on area_name(area_id);

-- full boundaries
create table area_geometry (
    area_id integer references area(id),
    -- centre of bounding rectangle
    centre_e double precision,
    centre_n double precision,
    -- bounding rectangle
    min_e double precision,
    min_n double precision,
    max_e double precision,
    max_n double precision,
    area double precision, -- in grid square units squared
    parts integer, -- number of parts in the polygon
    polygon bytea, -- a packed structure, NULL if not available
    primary key (area_id)
);

create index area_geometry_area_id_idx on area_geometry(area_id);

-- lookup table for postcodes
create table postcode (
    id serial not null primary key,
    postcode varchar(8) not null,
    -- Coordinate system. 'G' indicates eastings and northings referenced to
    -- the Ordnance Survey National Grid (defined on the OSGB36 ellipsoid);
    -- 'I' indicates eastings and northings referenced to the Irish Grid.
    coordsyst char(1) not null check (coordsyst = 'G' or coordsyst = 'I'),
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
-- Needed to make reverse lookups take a sane amount of time, sadly.
create index postcode_area_area_id_idx on postcode_area(area_id);

-- Horrid hack for new Scottish constituency boundaries
create table new_scottish_constituencies_fixup (
    council_area_id integer references area(id),
    ward_area_id integer references area(id),
    constituency_area_id integer not null references area(id)
);

create unique index new_scottish_constituencies_fixup_ward_area_id_idx
    on new_scottish_constituencies_fixup(ward_area_id);

create unique index new_scottish_constituencies_fixup_council_area_id_idx
    on new_scottish_constituencies_fixup(council_area_id);

