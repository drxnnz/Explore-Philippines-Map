# Explore Philippines Map — User Tracking Setup

This version adds a first-visit name gate, anonymous browser ID, Vercel Web Analytics, and optional Supabase cloud records.

## 1. Create the free Supabase project

Create a project at https://supabase.com/ and stay on the Free plan.

The current Free plan includes a 500 MB Postgres database, 50,000 monthly active users, and Realtime with 200 peak connections. Free projects can pause after 1 week of inactivity, so this is intended for a student/personal project and low-to-moderate usage.

## 2. Create the database tables/functions

Open Supabase → SQL Editor → New query.

Copy everything from `supabase_user_tracking.sql` into the editor and run it.

## 3. Get the public browser credentials

Supabase → Project Settings → API.

Copy:
- Project URL
- Publishable/anon public key

Do NOT put the `service_role`/secret key in the HTML.

## 4. Put the credentials into index(8).html

Find this block near the bottom of the file:

```js
const SUPABASE_URL = "YOUR_SUPABASE_PROJECT_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
```

Replace only those two values with your Supabase Project URL and public anon/publishable key.

Example shape (not real credentials):

```js
const SUPABASE_URL = "https://abcdefghijklmnop.supabase.co";
const SUPABASE_ANON_KEY = "eyJ...public-key...";
```

## 5. Enable Vercel Web Analytics

In Vercel:

Project → Analytics → Enable Web Analytics.

Then redeploy the project. Vercel's plain-HTML setup uses the `/_vercel/insights/script.js` route after Analytics is enabled.

## 6. What gets recorded

`pmm_users`:
- anonymous browser UUID
- name entered by the user
- first seen
- last seen
- session count
- quiz started count
- quiz completed count
- last mode

`pmm_user_events`:
- user ID
- name snapshot
- session ID
- event type
- mode
- event time
- small JSON payload

`pmm_presence`:
- user ID
- name
- current mode
- last heartbeat

Online count is calculated from presence rows seen within the last 90 seconds.

## 7. Important identity behavior

The ID is anonymous/pseudonymous and stored in the browser's Local Storage. It identifies a browser/device, not a guaranteed real-world person.

If a user clears site data, uses private browsing, or switches device/browser, a new anonymous ID can be generated.

The name is separately copied to Supabase so it can be viewed in the database. It is not limited to Local Storage.
