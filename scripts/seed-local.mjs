// Builds a small, realistic test community in the LOCAL Supabase stack:
// five members around Indiranagar, Bengaluru, with pets, photos, a Pawmate
// connection, a chat, a pending Sniff request, an upcoming playdate invite,
// a finished playdate to review and one member waiting for verification.
//
//   npm run seed:local        (Supabase must be running: npm start)
//
// Safe to re-run: it first deletes every *@pawmates.test account.
// Refuses to run against anything but 127.0.0.1 / localhost.
import { execSync } from "node:child_process";
import { deflateSync } from "node:zlib";
import { createClient } from "@supabase/supabase-js";

const PASSWORD = "Woof1234";
const DB_CONTAINER = "supabase_db_pawmates-backend";

// --- Local Supabase only --------------------------------------------------
const env = Object.fromEntries(
  execSync("npx supabase status -o env", { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
    .split(/\r?\n/)
    .map((line) => line.match(/^([A-Z_]+)="?([^"]*)"?$/))
    .filter(Boolean)
    .map((m) => [m[1], m[2]]),
);
const URL = env.API_URL;
const KEY = env.PUBLISHABLE_KEY;
if (!URL || !KEY) throw new Error("Local Supabase isn't running. Start it with: npm start");
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(URL)) {
  throw new Error(`Refusing to seed a non-local Supabase: ${URL}`);
}

const sql = (query) =>
  execSync(`docker exec -i ${DB_CONTAINER} psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tA`, {
    input: query,
    encoding: "utf8",
  }).trim();
const log = (text) => console.log(`  ${text}`);

// --- A solid-colour PNG, so cards have real images ------------------------
const CRC = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const byte of buf) c = CRC[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
function png(hex, size = 480) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  const row = Buffer.alloc(1 + size * 3);
  for (let x = 0; x < size; x++) row.set([r, g, b], 1 + x * 3);
  const raw = Buffer.concat(Array.from({ length: size }, () => row));
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body));
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// --- The community ----------------------------------------------------------
const MEMBERS = [
  {
    key: "you", email: "you@pawmates.test", name: "Dharma (test)", username: "dharma_test",
    bio: "Weekend park regular with a beagle who never stops sniffing.",
    area: "Indiranagar, Bengaluru", lat: 12.9784, lng: 77.6408, colour: "#cfeee9", admin: true,
    pet: { name: "Bruno", species: "dog", breed: "Beagle", birth_date: "2023-02-10", gender: "male", size: "medium", energy: "high", temperament: "friendly", play_style: "chaser", vaccinated: true, good_with_kids: true, good_with_cats: false, likes: ["fetch", "sniffing everything"], colour: "#ffd8c9" },
  },
  {
    key: "priya", email: "priya@pawmates.test", name: "Priya", username: "priya_test",
    bio: "Indie mum. Evening walks at Defence Colony Park.",
    area: "HAL 2nd Stage, Bengaluru", lat: 12.992, lng: 77.6408, colour: "#dbe6f5",
    pet: { name: "Luna", species: "dog", breed: "Indie", birth_date: "2024-01-05", gender: "female", size: "medium", energy: "high", temperament: "friendly", play_style: "chaser", vaccinated: true, good_with_kids: true, good_with_cats: true, likes: ["fetch", "water", "belly rubs"], colour: "#ffe7b8" },
  },
  {
    key: "arjun", email: "arjun@pawmates.test", name: "Arjun", username: "arjun_test",
    bio: "Coco is small but thinks she's a lion.",
    area: "Domlur, Bengaluru", lat: 12.961, lng: 77.6387, colour: "#e8f6f4",
    pet: { name: "Coco", species: "dog", breed: "Shih Tzu", birth_date: "2021-06-20", gender: "female", size: "small", energy: "medium", temperament: "shy", play_style: "gentle", vaccinated: true, likes: ["naps", "treats"], colour: "#f6d6e8" },
  },
  {
    key: "kavya", email: "kavya@pawmates.test", name: "Kavya", username: "kavya_test",
    bio: "Cat person, slowly being converted by the neighbourhood dogs.",
    area: "Koramangala, Bengaluru", lat: 12.9352, lng: 77.6245, colour: "#fff0ec",
    pet: { name: "Misty", species: "cat", breed: "Persian", birth_date: "2020-09-01", gender: "female", size: "small", energy: "low", temperament: "shy", play_style: "gentle", vaccinated: true, likes: ["sunny windows"], colour: "#e3e0f7" },
  },
  {
    key: "rahul", email: "rahul@pawmates.test", name: "Rahul", username: "rahul_test",
    bio: "New here! Rocky needs friends his size.",
    area: "Ulsoor, Bengaluru", lat: 12.9817, lng: 77.6195, colour: "#f4f8f8", pendingVerification: true,
    pet: { name: "Rocky", species: "dog", breed: "Labrador", birth_date: "2025-03-15", gender: "male", size: "large", energy: "high", temperament: "friendly", play_style: "wrestler", vaccinated: false, likes: ["swimming"], colour: "#d9efc4" },
  },
];

console.log(`Seeding ${URL}`);

// 1. Start clean: remove earlier test accounts (cascades to their data).
sql("delete from auth.users where email like '%@pawmates.test';");
log("removed earlier *@pawmates.test accounts");

// 2. Create, confirm and sign in every member.
const clients = {};
for (const m of MEMBERS) {
  const client = createClient(URL, KEY, { auth: { persistSession: false } });
  const { error } = await client.auth.signUp({ email: m.email, password: PASSWORD });
  if (error) throw new Error(`${m.email}: ${error.message}`);
  sql(`update auth.users set email_confirmed_at = now() where email = '${m.email}';`);
  const { data, error: signInError } = await client.auth.signInWithPassword({ email: m.email, password: PASSWORD });
  if (signInError) throw new Error(`${m.email}: ${signInError.message}`);
  clients[m.key] = { client, id: data.user.id, member: m };
}
log(`created ${MEMBERS.length} members (password ${PASSWORD})`);

// 3. Profiles, photos, location and pets, through the same rules the app uses.
const upload = async (client, bucket, folder, colour) => {
  const path = `${folder}/${crypto.randomUUID()}.png`;
  const { error } = await client.storage.from(bucket).upload(path, png(colour), { contentType: "image/png" });
  if (error) throw error;
  return { path, url: client.storage.from(bucket).getPublicUrl(path).data.publicUrl };
};

const petIds = {};
for (const { client, id, member: m } of Object.values(clients)) {
  const avatar = await upload(client, "avatars", id, m.colour);
  const { error } = await client.from("profiles").update({
    full_name: m.name, username: m.username, bio: m.bio, avatar_url: avatar.url,
    area_name: m.area, location: `POINT(${m.lng} ${m.lat})`, onboarded_at: new Date().toISOString(),
  }).eq("id", id);
  if (error) throw new Error(`${m.email} profile: ${error.message}`);

  const { colour, ...pet } = m.pet;
  const photos = [];
  for (const shade of [colour, colour, colour]) photos.push((await upload(client, "pet-photos", id, shade)).url);
  const { data: petRow, error: petError } = await client.from("pets").insert({ ...pet, photos }).select("id").single();
  if (petError) throw new Error(`${m.email} pet: ${petError.message}`);
  petIds[m.key] = petRow.id;

  if (m.pendingVerification) {
    const face = await upload(client, "verification-photos", id, m.colour);
    const withPet = await upload(client, "verification-photos", id, colour);
    const { error: vError } = await client.from("verifications").insert({ profile_photo_path: face.path, pet_photo_path: withPet.path });
    if (vError) throw new Error(`${m.email} verification: ${vError.message}`);
  }
}
log("profiles, avatars, pets and pet photos added");

// 4. Verification (and admin) as the team would grant it.
const verified = MEMBERS.filter((m) => !m.pendingVerification).map((m) => `'${m.email}'`).join(",");
sql(`update public.profiles p set verification_status = 'verified', verified_at = now()
     from auth.users u where u.id = p.id and u.email in (${verified});
     update public.profiles p set is_admin = true from auth.users u where u.id = p.id and u.email = 'you@pawmates.test';`);
log("verified everyone except Rahul (he's in the admin queue)");

// 5. Connections: you + Priya are Pawmates; Arjun is waiting on you.
const you = clients.you;
const priya = clients.priya;
await priya.client.from("connections").insert({ addressee_id: you.id, pet_id: petIds.priya, target_pet_id: petIds.you, message: "Luna saw Bruno at the park and wants to play!" });
const { data: req } = await you.client.from("connections").select("id").eq("requester_id", priya.id).single();
await you.client.rpc("respond_to_sniff", { connection_id: req.id, accept: true });
await clients.arjun.client.from("connections").insert({ addressee_id: you.id, pet_id: petIds.arjun, target_pet_id: petIds.you, message: "Coco is shy but loves calm beagles. Walk together?" });
log("you + Priya are Pawmates; Arjun sent you a Sniff request");

// 6. A chat with history.
const { data: conv } = await priya.client.rpc("get_or_create_direct_conversation", { other_user: you.id });
for (const [who, body] of [
  [priya, "Hi! Luna had so much fun watching Bruno chase that ball 😄"],
  [you, "Haha he never gets tired. Same time next week?"],
  [priya, "Definitely. I'll send you a proper invite."],
]) {
  await who.client.from("messages").insert({ conversation_id: conv, type: "text", body });
}

// 7. An upcoming playdate invite from Priya, waiting for your answer.
const tomorrow = new Date(Date.now() + 26 * 60 * 60 * 1000);
tomorrow.setMinutes(0, 0, 0);
const { error: pdError } = await priya.client.rpc("create_playdate", {
  conv, starts_at: tomorrow.toISOString(), duration_minutes: 60, lat: 12.9871, lng: 77.6408,
  place_name: "Defence Colony Park", address: "Defence Colony Park, Indiranagar, Bengaluru",
  note: "Zoomies at the park? Bring a ball!", my_pet_ids: [petIds.priya],
});
if (pdError) throw new Error(`playdate: ${pdError.message}`);

// 8. A finished playdate you both went to, so you can leave a review.
sql(`
  with ev as (
    insert into public.events (host_id, conversation_id, type, title, starts_at, ends_at, location, address, place_name)
    values ('${you.id}', '${conv}', 'playdate', 'Playdate at Cubbon Park',
            now() - interval '2 days 2 hours', now() - interval '2 days 1 hour',
            extensions.st_point(77.5946, 12.9763)::extensions.geography, 'Cubbon Park, Bengaluru', 'Cubbon Park')
    returning id
  ), att as (
    insert into public.event_attendees (event_id, user_id, status, pet_ids, responded_at)
    select ev.id, x.uid, 'going', x.pets, now() - interval '3 days' from ev,
      (values ('${you.id}'::uuid, array['${petIds.you}'::uuid]), ('${priya.id}'::uuid, array['${petIds.priya}'::uuid])) x(uid, pets)
    returning event_id
  )
  insert into public.messages (conversation_id, sender_id, type, body, metadata, created_at)
  select '${conv}', '${you.id}', 'invite', 'Cubbon Park this Saturday?', jsonb_build_object('event_id', ev.id), now() - interval '4 days'
  from ev;
`);
log("chat with Priya: messages, an upcoming playdate invite and a finished playdate to review");

// 9. Groups: you're in Priya's walking group (with a group chat and an
// upcoming event); Kavya's cat group is nearby for you to discover.
const kavya = clients.kavya;
const { data: walkers, error: gError } = await priya.client.rpc("create_group", {
  name: "Indiranagar Dog Walkers", kind: "area",
  description: "Morning and weekend walks around Indiranagar. All sizes welcome, leashes on near the road.",
});
if (gError) throw new Error(`group: ${gError.message}`);
const { data: walkersChat } = await you.client.rpc("join_group", { g: walkers });
await kavya.client.rpc("join_group", { g: walkers });
for (const [who, body] of [
  [priya, "Welcome everyone! 🐾 Post your walk times here."],
  [kavya, "Misty is a cat so I'll mostly lurk, but I know the best chai stall near the park 😄"],
]) {
  await who.client.from("messages").insert({ conversation_id: walkersChat, type: "text", body });
}
const sunday = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000);
sunday.setHours(7, 30, 0, 0);
const { error: evError } = await priya.client.rpc("create_group_event", {
  g: walkers, title: "Sunday pack walk", starts_at: sunday.toISOString(), duration_minutes: 90,
  lat: 12.9763, lng: 77.5929, place_name: "Cubbon Park", address: "Cubbon Park, Kasturba Road, Bengaluru",
  description: "Easy loop around the park, then water and treats by the bandstand.", capacity: 10,
  my_pet_ids: [petIds.priya],
});
if (evError) throw new Error(`event: ${evError.message}`);
await kavya.client.rpc("create_group", {
  name: "Bengaluru Cat Parents", kind: "interest", species: "cat",
  description: "Tips, vets, sitters and the occasional cat café meetup.",
});
log("groups: you're in Indiranagar Dog Walkers (Sunday pack walk); Bengaluru Cat Parents is nearby");

console.log(`
Done. Sign in at http://localhost:3000/login with password ${PASSWORD}:

  you@pawmates.test     Dharma (test) + Bruno   admin, verified   <- start here
  priya@pawmates.test   Priya + Luna            your Pawmate
  arjun@pawmates.test   Arjun + Coco            sent you a Sniff request
  kavya@pawmates.test   Kavya + Misty (cat)     nearby, not connected
  rahul@pawmates.test   Rahul + Rocky           waiting for verification (see /admin)
`);
