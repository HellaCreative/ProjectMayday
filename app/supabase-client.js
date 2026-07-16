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
    const { data, error } = await db.from("group_members").select("role, groups(id,name,owner_id,invite_code,created_at)").eq("user_id", userId);
    if (error) throw error;
    return (data || []).map((row) => Object.assign({}, row.groups, { role: row.role }));
  }

  async function joinGroup(inviteCode, userId) {
    const db = await init();
    const { data: group, error } = await db.from("groups").select("id,name,owner_id,invite_code,created_at").eq("invite_code", String(inviteCode || "").trim().toUpperCase()).single();
    if (error) throw error;
    const { error: memberError } = await db.from("group_members").upsert({ group_id: group.id, user_id: userId, role: "member" }, { onConflict: "group_id,user_id" });
    if (memberError) throw memberError;
    return group;
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

  global.DirtSupabase = { init, sendEmailCode, verifyEmailCode, signOut, session, user, updateDisplayName, onAuthStateChange, createGroup, listGroups, joinGroup, listMembers, savePresence, saveAlert, openGroupChannel, closeGroupChannel };
})(window);
