# PDE Analisi

App del PDE Hub (sezione Tool interni) per le analisi sui dati Messaggerie.
Un solo `index.html`, pubblicato su GitHub Pages come `albertospde.github.io/pde-analisi/`
e aperto dal Hub in una scheda interna.

- Login con l'account Supabase condiviso con il Hub e le altre app PDE (progetto "presenze").
- Accesso riservato agli amministratori PDE (`_is_admin_pde()`).
- Per ora la schermata principale è vuota: le analisi arriveranno dai file che la edge function
  `sftp-messaggerie` (Giro Manager) scarica ogni mattina dall'SFTP di Messaggerie.

Logo: `py scripts/crea_logo.py` (stesso stile di Giro Manager e PDE Festival).
