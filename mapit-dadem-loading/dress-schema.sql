--
-- dress-schema.sql:
-- Schema for the Dress Postgres database.
--
-- Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
-- Email: matthew@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: dress-schema.sql,v 1.1 2007-03-17 12:42:12 matthew Exp $
--

-- lookup table for addresses
create table address (
    id serial not null primary key,
    -- Was "real" as that would be smaller, but it doesn't work? XXX
    easting double precision not null,
    northing double precision not null,
    coordsyst char(1) not null check (coordsyst = 'G' or coordsyst = 'I'),
    address text not null,
    postcode varchar(8) not null
);

create index address_postcode_idx on address(postcode);
create index address_easting_northing_idx on address(easting, northing);

create type address_nearby_match as (
    address_id integer,
    distance double precision   -- km
);

-- address_find_nearest EASTING NORTHING
-- Find nearest addresss to (EASTING, NORTHING).
create function address_find_nearest(double precision, double precision)
    returns setof address_nearby_match as
'
    select address.id,
           sqrt(($1 - easting) ^ 2
                + ($2 - northing) ^ 2)
            as distance
        from address
        where
	    easting > ($1 - 1000) and easting < ($1 + 1000)
	    and northing > ($2 - 1000) and northing < ($2 + 1000)
        order by distance
	limit 1
' language sql; -- should be "stable" rather than volatile per default?

