create table area (
    id integer not null primary key,
    parent_area_id integer,
    unit_id integer,        -- ESRI shapefile unit ID
    name text not null,
    ons_code text,
    type char(3)            -- 'CTY' or whatever
);
create table postcode (
    postcode varchar(8) not null primary key,
    id integer not null,
    easting number,
    northing number
);
create table postcode_area (
    postcode_id integer not null,
    area_id integer not null
);
create index postcode_area_postcode_id_idx on postcode_area(postcode_id);
create unique index postcode_id_idx on postcode(id);
