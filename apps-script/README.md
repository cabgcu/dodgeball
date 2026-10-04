# Google Sheets backend

`Code.gs` is the whole backend. It's a Google Apps Script web app, and a Google Sheet holds all the data.

1. Create a blank Google Sheet, then go to **Extensions ▸ Apps Script** and paste in `Code.gs`.
2. Run `setup` once and approve the permissions. It creates every tab, header, checkbox and format:
   `Settings`, `Teams`, `Players`, `Bracket`, `Timers` and `Log`.
3. **Deploy ▸ New deployment ▸ Web app**. Set Execute as **Me** and Who has access **Anyone**, then copy the `/exec` URL.
4. Paste the URL into `API_URL` at the top of the main `<script>` in `index.html`.
5. Reload the Sheet, then use **Dodgeball ▸ Set admin password** to change the default password.

After editing the script, go to **Deploy ▸ Manage deployments ▸ edit ▸ New version** so the change goes live.
