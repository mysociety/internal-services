--
-- schema.sql:
-- Schema for representative-editing interface.
--
-- Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.1 2004-12-15 19:00:15 chris Exp $
--

-- A set of data obtained from an outside source.
create table dataset (
    id serial not null primary key,
    day text not null,
    filename text not null,
);

-- Types of area (ward-level) which this dataset describes.
create table dataset_area (
    dataset_id integer not null references dataset(id),
    area_type char(3) not null references area
);

-- Original data obtained from the outside source.
create table original (
    dataset_id integer not null references dataset(id),
    id serial not null,         -- line number, essentially
    name text not null,
    area1 text not null,        -- ward, electoral division, constituency, ...
    area2 text not null,        -- council, assembly, parliament, ...
    party text not null,
    email text not null,
    fax text not null,
    primary key (version_id, id)
);

-- Changes applied to clean the original data.
create table change (
    id serial not null primary key,
    version_id integer not null,

    -- Possible actions are:
    -- 
    -- add          add a whole line of data
    -- delete       delete a whole line of data
    -- edit         replace a whole line of data
    -- substitute   substitute one ward name for another
    -- 
    -- Lines are identified by matching name, area1 and area2.
    action text not null check (action = 'add' or action = 'delete' or action = 'edit' or action = 'substitute'),
    
    name text,
    area1 text,
    area2 text,
    party text,
    email text,
    fax text
);
