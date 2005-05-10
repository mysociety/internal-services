--
-- new-scottish-constituencies-fixup-table.sql:
-- Fixup table for identifying new Scottish constituencies from the wards or
-- councils which make them up.
--
-- Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: new-scottish-constituencies-fixup-table.sql,v 1.2 2005-05-10 13:52:46 chris Exp $
--

create table new_scottish_constituencies_fixup (
    council_area_id integer references area(id),
    ward_area_id integer references area(id),
    constituency_area_id integer not null references area(id)
);

create unique index new_scottish_constituencies_fixup_ward_area_id_idx
    on new_scottish_constituencies_fixup(ward_area_id);

create unique index new_scottish_constituencies_fixup_council_area_id_idx
    on new_scottish_constituencies_fixup(council_area_id);
