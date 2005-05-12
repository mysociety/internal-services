--
-- new-scottish-constituencies-update-generations.sql:
-- Bump all generation numbers except those for old Scottish constituencies.
--
-- Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: new-scottish-constituencies-update-generations.sql,v 1.2 2005-05-12 14:43:33 chris Exp $
--

-- XXX should check actual value of generation_high
update area set generation_high = 2 where country = 'E' or country = 'W';
update area set generation_high = 2 where country = 'S' and type <> 'WMC';
update area set generation_high = 2, generation_low = 2
where country = 'S'
    and (
        select constituency_area_id from new_scottish_constituencies_fixup
        where constituency_area_id = id
        limit 1
    ) is not null;
