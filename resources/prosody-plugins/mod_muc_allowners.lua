local filters = require 'util.filters';
local jid = require "util.jid";
local jid_bare = require "util.jid".bare;
local um_is_admin = require "core.usermanager".is_admin;
local util = module:require "util";
local is_healthcheck_room = util.is_healthcheck_room;
local extract_subdomain = util.extract_subdomain;
local presence_check_status = util.presence_check_status;
local MUC_NS = 'http://jabber.org/protocol/muc';

local moderated_subdomains;
local moderated_rooms;

local function load_config()
    moderated_subdomains = module:get_option_set("allowners_moderated_subdomains", {})
    moderated_rooms = module:get_option_set("allowners_moderated_rooms", {})
end
load_config();

local function is_admin(jid)
    return um_is_admin(jid, module.host);
end

-- List of the bare_jids of all occupants that are currently joining (went through pre-join) and will be promoted
-- as moderators. As pre-join (where added) and joined event (where removed) happen one after another this list should
-- have length of 1
local joining_moderator_participants = {};

-- Checks whether the jid is moderated, the room name is in moderated_rooms
-- or if the subdomain is in the moderated_subdomains
-- @return returns on of the:
--      -> false
--      -> true, room_name, subdomain
--      -> true, room_name, nil (if no subdomain is used for the room)
local function is_moderated(room_jid)
    if moderated_subdomains:empty() and moderated_rooms:empty() then
        return false;
    end

    local room_node = jid.node(room_jid);
    -- parses bare room address, for multidomain expected format is:
    -- [subdomain]roomName@conference.domain
    local target_subdomain, target_room_name = extract_subdomain(room_node);
    if target_subdomain then
        if moderated_subdomains:contains(target_subdomain) then
            return true, target_room_name, target_subdomain;
        end
    elseif moderated_rooms:contains(room_node) then
        return true, room_node, nil;
    end

    return false;
end

module:hook("muc-occupant-pre-join", function (event)
    local room, occupant = event.room, event.occupant;

    if is_healthcheck_room(room.jid) or is_admin(occupant.bare_jid) then
        return;
    end

    local moderated, room_name, subdomain = is_moderated(room.jid);
    if moderated then
        local session = event.origin;
        local token = session.auth_token;

        if not token then
            module:log('debug', 'skip allowners for non-auth user subdomain:%s room_name:%s', subdomain, room_name);
            return;
        end

        if not (room_name == session.jitsi_meet_room or session.jitsi_meet_room == '*') then
            module:log('debug', 'skip allowners for auth user and non matching room name: %s, jwt room name: %s', room_name, session.jitsi_meet_room);
            return;
        end

        if not (subdomain == session.jitsi_meet_context_group) then
            module:log('debug', 'skip allowners for auth user and non matching room subdomain: %s, jwt subdomain: %s', subdomain, session.jitsi_meet_context_group);
            return;
        end
    end

    -- mark this participant that it will be promoted and is currently joining
    joining_moderator_participants[occupant.bare_jid] = true;
end, 2);

module:hook("muc-occupant-joined", function (event)
    local room, occupant = event.room, event.occupant;

    local promote_to_moderator = joining_moderator_participants[occupant.bare_jid];
    -- clear it
    joining_moderator_participants[occupant.bare_jid] = nil;

    if promote_to_moderator ~= nil then
        room:set_affiliation(true, occupant.bare_jid, "owner");
    end
end, 2);

module:hook("muc-occupant-left", function (event)
    local room, occupant = event.room, event.occupant;

    if is_healthcheck_room(room.jid) then
        return;
    end

    room:set_affiliation(true, occupant.bare_jid, nil);
end, 2);

module:hook_global('config-reloaded', load_config);

-- Filters self-presences to a jid that exist in joining_participants array
-- We want to filter those presences where we send first `participant` and just after it `moderator`
function filter_stanza(stanza)
    if not stanza.attr or not stanza.attr.to or stanza.name ~= "presence" then
        return stanza;
    end

    -- Allow self-presence (code=110)
    local bare_to = jid_bare(stanza.attr.to);

    if joining_moderator_participants[bare_to] then
        if presence_check_status(stanza:get_child('x', MUC_NS..'#user'), '110') then
            return nil;
        end
    end

    return stanza;
end
function filter_session(session)
    -- domain mapper is filtering on default priority 0, and we need it after that
    filters.add_filter(session, 'stanzas/out', filter_stanza, -1);
end

-- enable filtering presences
filters.add_filter_hook(filter_session);
