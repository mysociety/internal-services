--
-- mapit-schema.sql:
-- Schema for the DaDem Postgres database.
--
-- Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
-- Email: francis@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: dadem-schema.sql,v 1.12 2005-01-21 19:28:03 francis Exp $
--

-- data about each democratic reperesentative
create table representative (
    id serial not null primary key,
    area_id integer not null,
    area_type char(3) not null,
    name text not null,
    party text not null,
    -- either means "fax or email is good, up to queue to decide"
    -- shame means "refuses to be contacted"
    -- unknown means "we don't have good data"
    method text not null check (method in('either','fax','email','shame','unknown')),
    email text,
    fax text
);
create index representative_area_id_idx on representative(area_id);

-- data edited from web interface
-- NULL values mean leave unchanged
-- this is a transaction log, only later values count
create table representative_edited (
    order_id serial not null primary key,
    representative_id integer references representative(id),

    name text,
    party text,
    -- either means "fax or email is good, up to queue to decide"
    -- shame means "refuses to be contacted"
    -- unknown means "we don't have good data"
    method text check (method in('either','fax','email','shame','unknown')),
    email text,
    fax text,

    -- name of person who edited it
    editor text not null,
    -- time of entry in UNIX time
    whenedited integer not null, 
    -- what the change was for: author's notes
    note text not null
);

/*
Disabled until ready

-- data about elected body
create table electedbody (
    id serial not null primary key,
    area_id integer not null,
    area_type char(3) not null,
    name text not null,
    -- General web information about the body.
    webpage text not null,
    -- The "representative contact" is, e.g., a Democratic Services Officer or
    -- other contact point for contacting one of the elected body's 
    -- representatives. Contact methods are as above, but there is no "shame"
    -- type for elected bodies. We add a postal address too, as a possible
    -- fallback for "shame" cases where we have no other representative contact
    -- details.
    representative_contact_method text not null check (representative_contact_method in ('either', 'fax', 'email', 'unknown'),
    representative_contact_email text,
    representative_contact_fax text,
    representative_contact_address text
);

create index electedbody_area_id_idx on electedbody(area_id);

-- editing data about elected bodies; semantics as for representative_edited
create table electedbody_edited (
    order_id serial not null primary key,
    electedbody_id integer references electedbody(id),

    name text,
    webpage text,
    representative_contact_method text not null check (representative_contact_method in ('either', 'fax', 'email', 'unknown'),
    representative_contact_email text,
    representative_contact_fax text,
    representative_contact_address text,
    
    editor text not null,
    whenedited integer not null,
    note text not null
);
*/

-- original input data from CSV file, only "council" name matched into standard
-- form, "ward" names could contain anything.
create table raw_input_data (
    raw_id serial not null primary key,
    ge_id int not null,

    council_id integer not null,
    council_name text not null, -- in canonical 'C' form
    council_type char(3) not null, 

    ward_name text,

    rep_name text,
    rep_party text,
    rep_email text,
    rep_fax text

);

create unique index raw_input_data_ge_id_idx on raw_input_data(ge_id);
create index council_id_idx on raw_input_data(countil_id);
create index council_name_idx on raw_input_data(council_name);
create index council_type_idx on raw_input_data(council_type);

create table raw_process_status (
    council_id integer not null,
    
    status text not null,
    details text not null
);

create index raw_process_status_status_idx on raw_process_status(status);


