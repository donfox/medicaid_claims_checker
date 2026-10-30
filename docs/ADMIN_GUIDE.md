# Admin Guide

Managing user accounts. Everything here happens on the **Admin** page
(`/admin`), which only admins can open: they see an **Admin** link in the top
menu, and anyone else who opens the address is sent back to the home page.
The app sends no email; every step is done on this page.

## The first admin

`./setup.sh` runs the database seeds. When the database has **no admin at
all**, they create one and print its email and password:

- Email `admin@example.com` and username `admin`, unless `SEED_ADMIN_EMAIL`
  and `SEED_ADMIN_USERNAME` say otherwise.
- In development and tests the password is `AdminPassword123!`, so a fresh
  local setup can log in straight away. Anywhere else it is
  `SEED_ADMIN_PASSWORD`, or, if that is unset, a random password printed once.

Once any admin exists the seeds create nothing, so removing the seeded
account's admin role or deactivating it is permanent. A good first step is to
make your own account an admin (below), then do that to the seeded account.

## Registration

The **User Registration** switch under **System** decides whether new people
can create accounts at `/users/register`.

- **Open**: anyone who can reach the app can register. They choose their own
  password and are logged in straight away.
- **Closed**: the registration page sends visitors to the log-in page with
  "Registration is currently closed."

New accounts are ordinary users. Only an admin can make another admin.

## The Users table

Every account, oldest first, with its name, email, the date it joined, and
badges:

- **Active** or **Inactive**
- **No password**, for accounts that cannot log in yet (see below)
- **Admin** or **User**

The buttons on each row:

| Button | What it does |
|---|---|
| **Deactivate** / **Activate** | An inactive user cannot use the app. Someone already logged in is logged out the next time they open a page, with "Your account has been deactivated. Please contact an administrator." The account is kept; **Activate** restores access. |
| **Make admin** / **Remove admin** | Gives or takes away access to this page. |
| **Create password link** | A one-time link for the user to set a new password. See below. |

You cannot deactivate your own account or change your own admin role, so the
app cannot be left without an admin by accident.

## Password links

Two kinds of user need one:

- **Accounts with no password.** Accounts made before the app had password
  registration have no password and cannot log in; their row shows **No
  password**.
- **Users who have forgotten their password.**

When either tries to log in, the log-in page says: "Invalid email or
password. If you don't have a password yet, or have forgotten it, ask an
administrator."

To let them in:

1. Click **Create password link** on their row. The account must be active.
2. A link appears at the top of the page. Copy it and give it to the user in
   any way you like: a message, a chat, in person.
3. They open it, choose a password (at least 12 characters, entered twice) and
   are logged in. The account is confirmed, the **No password** badge goes,
   and any other place they were logged in is logged out.

The link works **once** and **expires after 3 days**. It also stops working if
the user's email or password changes first. If it expires, create another;
creating a new link does not cancel an older one that is still unused.

Anyone holding the link can set that account's password, so give it only to
the user it is for.

## What users do themselves

On **Settings** (`/users/settings`), each user can change their email or their
password. The page asks them to log in again if their last log-in was more
than 20 minutes ago. An email change takes effect at once; a password change
logs out their other sessions.

## Limits to know about

- **No self-service reset.** A user who forgets their password needs an admin
  to create a link; the app sends no email.
- **No deleting accounts.** Accounts can be deactivated but not deleted.
