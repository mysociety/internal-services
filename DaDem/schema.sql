create table representative (
    id integer not null primary key,
    area_id integer not null,
    area_type char(3) not null,
    name text not null,
    party text not null,
    method integer not null,    -- 0: either, 1: fax, 2: email
    email text,
    fax text
);

