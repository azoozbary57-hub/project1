@echo off
cd /d "%~dp0"
start "Notes Sync Server" cmd /k "npm start"
start "Cloudflare Tunnel" cmd /k "cloudflared.exe tunnel --url http://localhost:8787"
