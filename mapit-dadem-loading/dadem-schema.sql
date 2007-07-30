--
-- mapit-schema.sql:
-- Schema for the DaDem Postgres database.
--
-- Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
-- Email: francis@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: dadem-schema.sql,v 1.39 2007-07-30 16:51:59 matthew Exp $
--

-- data about status of an area in relation to its representatives
-- for example, invalid because of election
create table area_status (
    area_id integer not null,
    status text not null check (status in('none','pending_election','recent_election','boundary_changes')) default 'none'
);
create unique index area_status_area_id_idx on area_status(area_id);

-- data about each democratic representative
create table representative (
    id serial not null primary key,
    area_id integer not null,
    area_type char(3) not null,
    name text not null,
    party text not null,
    -- either means "fax or email is good, up to queue to decide"
    -- shame means "refuses to be contacted"
    -- unknown means "we don't have good data"
    method text not null check (method in('either','fax','email','shame','unknown','via')),
    email text,
    fax text,

    -- such as GovEval id, etc.
    import_key text,
    -- time of entry creation in UNIX time
    -- NOTE: This field was added 2006-02-08, with old data generated using backup files
    -- Old data will not be particularly accurate. It isn't a very accurate field anyway,
    -- as it depends on when data was updated, not when the representative took office.
    -- In particular, the first edited data in representative_edited may be a day or two
    -- earlier than this date.
    whencreated integer not null
);
create index representative_area_id_idx on representative(area_id);
-- sometimes the same goveval key applies to two areas, for example when a councillor moves
-- ward and GovEval keep same id (then duplicate will apply briefly until update system has
-- updated both), or their ward alters boundaries and is given a new id by us (when the 
-- councillor is permanently present in both, although one area will have an old generation)
create unique index representative_import_key_area_id_idx on representative(import_key, area_id);

-- data edited from web interface
-- NULL values mean leave unchanged
-- this is a transaction log, only later values count
create table representative_edited (
    order_id serial not null primary key,
    representative_id integer references representative(id),

    -- if representative is no longer in office
    deleted boolean default(false),

    name text,
    party text,
    -- either means "fax or email is good, up to queue to decide"
    -- shame means "refuses to be contacted"
    -- unknown means "we don't have good data"
    -- via means "don't contact this representative directly, but obtain
    -- general contact details for the enclosing area, and use those"
    method text check (method in('either','fax','email','shame','unknown','via')),
    email text,
    fax text,

    -- name of person who edited it
    editor text not null,
    -- time of entry in UNIX time
    whenedited integer not null, 
    -- what the change was for: author's notes
    note text not null
);

create index representative_edited_representative_id_idx on representative_edited(representative_id);

-- original input data from CSV file (from GovEval), only "council" name
-- matched into standard form, "ward" names could contain anything.
create table raw_input_data (
    raw_id serial not null primary key,
    ge_id integer not null,

    council_id integer not null,
    council_name text not null, -- in canonical 'C' form
    council_type char(3) not null, 
    council_ons_code varchar(7) not null,    -- 6+-digit ward code

    ward_name text,

    rep_first text,
    rep_last text,
    rep_party text,
    rep_email text,
    rep_fax text
);

create unique index raw_input_data_ge_id_idx on raw_input_data(ge_id);
create index raw_input_data_council_id_idx on raw_input_data(council_id);
create index raw_input_data_council_name_idx on raw_input_data(council_name);
create index raw_input_data_council_type_idx on raw_input_data(council_type);

-- alterations to raw_input_data as a transaction log
create table raw_input_data_edited (
    -- order in which rows override each other
    order_id serial not null primary key,

    -- one of these is always null, the other has a value
    ge_id integer, -- key for altering existing rows
    newrow_id integer, -- key for added rows
    check ( (ge_id is not null and newrow_id is null) or
            (newrow_id is not null and ge_id is null) ),
    alteration text not null check (alteration in('modify','delete')),

    -- extra key data for recovery if something goes wrong
    council_id integer not null,
    council_name text not null, -- in canonical 'C' form
    council_type char(3) not null, 
    council_ons_code varchar(7) not null,    -- 6+-digit ward code

    -- modified values, all must be there
    ward_name text not null,
    rep_first text not null,
    rep_last text not null,
    rep_party text not null,
    rep_email text not null,
    rep_fax text not null,

    -- name of person who edited it
    editor text not null,
    -- time of entry in UNIX time
    whenedited integer not null, 
    -- what the change was for: author's notes
    note text not null
);

create index raw_input_data_edited_ge_id_idx on raw_input_data_edited(ge_id);
create index raw_input_data_edited_newrow_id_idx on raw_input_data_edited(newrow_id);
create index raw_input_data_edited_council_id_idx on raw_input_data_edited(council_id);

create sequence raw_input_data_edited_newrow_seq;

-- extra info about council that user has put in match interface
create table raw_council_extradata (
    council_id integer not null,

    -- council web page with list of all councillors on it
    councillors_url text not null,

    -- whether to make council live
    make_live boolean not null default (false)
);


-- how well the data in raw_input_data has been name matched and/or
-- read into the main representatives table
create table raw_process_status (
    council_id integer not null,
    
    status text not null,
    error text,
    details text not null
);

create index raw_process_status_status_idx on raw_process_status(status);

-- data that users have entered on the website to correct representatives
create table user_corrections (
    user_correction_id serial not null primary key,

    voting_area_id integer,
    representative_id integer,  -- can be null for "add" items
    alteration text not null check (alteration in('modify','delete','add')),
    name text not null,
    party text not null,

    user_notes text not null,
    user_email text not null,
    whenentered integer not null,

    admin_done boolean not null default 'f',
    when_goveval integer -- when report was sent to goveval
);

-- maps MPs to their person id in parlparse
create table parlparse_link (
    representative_id integer primary key references representative(id),
    person_id text not null
);

create index parlparse_link_person_id on parlparse_link(person_id);


