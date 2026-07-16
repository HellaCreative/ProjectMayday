(function (global) {
  "use strict";

  let client = null;
  let currentGroupChannel = null;

  async function init() {
    if (client) return client;
    if (!global.supabase || typeof global.supabase.createClient !== "function") throw new Error("Supabase client library is unavailable.");
    const response = await fetch("/api/supabase-config", { cache: "no-store" });
    const config = await response.json();
    if (!config.url || !config.publishableKey) throw new Error("Supabase is not configured for this deployment.");
    client = global.supabase.createClient(config.url, config.publishableKey, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
    });
    return client;
  }

  async function sendEmailCode(email, displayName) {
    const db = await init();
    return db.auth.signInWithOtp({
      email,
      options: {
        shouldCreateUser: true,
        data: { display_name: displayName || "" }
      }
    });
  }

  async function verifyEmailCode(email, token) {
    const db = await init();
    return db.auth.verifyOtp({ email, token, type: "email" });
  }

  async function signOut() {
    const db = await init();
    return db.auth.signOut();
  }

  async function session() {
    const db = await init();
    return db.auth.getSession();
  }

  async function user() {
    const db = await init();
    return db.auth.getUser();
  }

  async function updateDisplayName(displayName) {
    const db = await init();
    const name = String(displayName || "").trim().slice(0, 60);
    const { data, error } = await db.auth.updateUser({ data: { display_name: name } });
    if (error) throw error;
    if (!data?.user?.id) throw new Error("Your profile could not be updated.");
    const { error: profileError } = await db.from("profiles").upsert(
      { id: data.user.id, display_name: name, updated_at: new Date().toISOString() },
      { onConflict: "id" }
    );
    if (profileError) throw profileError;
    return data.user;
  }

  async function onAuthStateChange(callback) {
    const db = await init();
    return db.auth.onAuthStateChange(callback);
  }

  async function createGroup(name, ownerId) {
    const db = await init();
    const { data: sessionData } = await db.auth.getSession();
    const sessionUserId = sessionData?.session?.user?.id;
    if (!sessionUserId) throw new Error("Your sign-in session has expired. Verify your email code again.");
    const { data: group, error } = await db.from("groups").insert({ name, owner_id: sessionUserId }).select().single();
    if (error) throw error;
    const { error: memberError } = await db.from("group_members").insert({ group_id: group.id, user_id: sessionUserId, role: "owner" });
    if (memberError) throw memberError;
    return group;
  }

  async function listGroups(userId) {
    const db = await init();
    const { data, error } = await db.from("group_members").select("role, groups(id,name,owner_id,invite_code,created_at,deleted_at)").eq("user_id", userId);
    if (error) throw error;
    const groups = (data || []).map((row) => Object.assign({}, row.groups, { role: row.role }));
    const groupIds = groups.map((group) => group.id).filter(Boolean);
    if (!groupIds.length) return groups;
    const { data: memberships, error: membershipError } = await db.from("group_members").select("group_id,user_id").in("group_id", groupIds);
    if (membershipError) throw membershipError;
    const userIds = [...new Set((memberships || []).map((row) => row.user_id).filter(Boolean))];
    const { data: presence, error: presenceError } = userIds.length
      ? await db.from("rider_presence").select("user_id,sharing_enabled,last_seen_at").in("user_id", userIds)
      : { data: [], error: null };
    if (presenceError) throw presenceError;
    const liveByUser = new Map((presence || []).filter((row) => {
      if (row.sharing_enabled !== true) return false;
      if (!row.last_seen_at) return true;
      const lastSeen = Date.parse(row.last_seen_at);
      return Number.isNaN(lastSeen) || Date.now() - lastSeen < 120000;
    }).map((row) => [row.user_id, true]));
    return groups.map((group) => {
      const members = (memberships || []).filter((row) => row.group_id === group.id);
      const liveCount = members.filter((row) => liveByUser.has(row.user_id)).length;
      return Object.assign({}, group, { member_count: members.length, live_count: liveCount });
    });
  }

  async function joinGroup(inviteCode, userId) {
    const db = await init();
    const code = String(inviteCode || "").trim().toLowerCase();
    if (!/^[a-z0-9]{6}$/.test(code)) throw new Error("Invite codes are six lowercase letters or numbers.");
    const { data, error } = await db.rpc("join_group_by_invite_code", { p_invite_code: code });
    if (error) throw error;
    const group = Array.isArray(data) ? data[0] : data;
    if (!group) throw new Error("No active riding group was found for that code.");
    return group;
  }

  async function deleteGroup(groupId) {
    const db = await init();
    const { error } = await db.rpc("delete_group", { p_group_id: groupId });
    if (error) throw error;
  }

  async function leaveGroup(groupId) {
    const db = await init();
    const { error } = await db.rpc("leave_group", { p_group_id: groupId });
    if (error) throw error;
  }

  async function listMembers(groupId) {
    const db = await init();
    const { data, error } = await db.from("group_members").select("user_id,role,profiles(display_name)").eq("group_id", groupId);
    if (error) throw error;
    return data || [];
  }

  async function savePresence(payload) {
    const db = await init();
    return db.from("rider_presence").upsert(payload, { onConflict: "user_id" });
  }

  async function saveAlert(payload) {
    const db = await init();
    return db.from("rider_alerts").insert(payload).select().single();
  }

  async function openGroupChannel(groupId, userId, handlers) {
    const db = await init();
    if (currentGroupChannel) await db.removeChannel(currentGroupChannel);
    const channel = db.channel("group:" + groupId, { config: { private: true, presence: { key: userId } } });
    channel
      .on("presence", { event: "sync" }, () => handlers?.presence?.(channel.presenceState()))
      .on("presence", { event: "join" }, () => handlers?.presence?.(channel.presenceState()))
      .on("presence", { event: "leave" }, () => handlers?.presence?.(channel.presenceState()))
      .on("broadcast", { event: "location" }, ({ payload }) => handlers?.location?.(payload));
    const status = await new Promise((resolve, reject) => {
      channel.subscribe((value) => {
        if (value === "SUBSCRIBED") resolve(value);
        if (value === "CHANNEL_ERROR" || value === "TIMED_OUT") reject(new Error("Could not connect to the group channel."));
      });
    });
    currentGroupChannel = channel;
    return { status, track: (payload) => channel.track(payload), sendLocation: (payload) => channel.send({ type: "broadcast", event: "location", payload }) };
  }

  async function closeGroupChannel() {
    if (!client || !currentGroupChannel) return;
    await client.removeChannel(currentGroupChannel);
    currentGroupChannel = null;
  }

  global.DirtSupabase = { init, sendEmailCode, verifyEmailCode, signOut, session, user, updateDisplayName, onAuthStateChange, createGroup, listGroups, joinGroup, deleteGroup, leaveGroup, listMembers, savePresence, saveAlert, openGroupChannel, closeGroupChannel };
})(window);
