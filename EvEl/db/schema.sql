--
-- schema.sql:
-- Schema for the mailing list management component.
--
-- Copyright (c) 2005 Chris Lightfoot. All rights reserved.
-- Email: chris@ex-parrot.com; WWW: http://www.ex-parrot.com/~chris/
--
-- $Id: schema.sql,v 1.1 2005-03-17 17:40:56 chris Exp $
--

-- A message represents a single message which may be sent to one or more
-- recipients.
create table message (
    id serial not null primary key,
    data bytea not null,
    -- XXX add some stats about this message so that we can garbage-collect the
    -- data later on but keep the message record around for logging purposes.
    whensubmitted integer not null,
    isprobe boolean not null default(false)
);

-- A recipient is one of the targets of a mail. We identify recipients uniquely
-- by email address.
create table recipient (
    id serial not null primary key,
    address text not null
);

create unique index recipient_address_idx on recipient(address);

-- Table mapping messages to their recipients. We store information about
-- deliveries in this table until some time after the deliveries are complete,
-- so that we can gather bounces.
create table message_recipient (
    message_id integer not null references message(id),
    recipient_id integer not null references recipient(id),
    -- every time we try to submit the message for delivery, we update the
    -- numattempts counter and set whenlastattempt
    numattempts integer not null default 0,
    whenlastattempt integer,
    -- if we succeed in dispatching the message, we set whensent.
    whensent integer
);

-- A Table to collect bounces for individual addresses.
create table bounce (
    message_id integer not null references message(id),
    recipient_id integer not null references recipient(id),
    whenreceived integer not null,
    -- the complete text of the bounce (headers and body). This can be
    -- garbage-collected later on
    data bytea
    -- XXX add a field to distinguish temporary from permanent bounces, and try
    -- to keep it updated by pattern-matching on the bounces?
);

-- A mailinglist is a named collection of recipients owned by a particular
-- calling scope.
create table mailinglist (
    id serial not null primary key,
    -- scope and tag together uniquely identify each mailing list
    scope text not null,
    tag text not null,
    -- name is the human-readable name of the mailing list
    name text not null,
    -- local-part and domain indicate where the list lives
    localpart text not null,
    domain text not null,
    -- postingmode indicates who may post by sending mail to the list address
    postingmode varchar(16) not null check (
            -- anyone at all may post
            postingmode = 'any' or
            -- subscribers may post
            postingmode = 'subscribers' or
            -- subscribers who are marked as admins may post
            postingmode = 'admins' or
            -- nobody may post (i.e. mail may only be submitted through the API)
            postingmode = 'none'
        ),
    -- XXX do we want a "temporary" flag for lists which should be
    -- garbage-collected after they've been disused for a while?
    whencreated integer not null
);

create index mailinglist_scope_idx on mailinglist(scope);
create index mailinglist_tag_idx on mailinglist(tag);
create unique index mailinglist_scope_tag_idx on mailinglist(scope, tag);

-- Table to map recipients to mailing lists (as subscribers).
create table mailinglist_recipient (
    mailinglist_id integer not null references mailinglist(id),
    recipient_id integer not null references recipient(id),
    isadmin boolean not null default(false),
    primary key(mailinglist_id, recipient_id)
);

create index mailinglist_recipient_mailinglist_id_idx
    on mailinglist_recipient(mailinglist_id);

create index mailinglist_recipient_recipient_id_idx
    on mailinglist_recipient(recipient_id);

