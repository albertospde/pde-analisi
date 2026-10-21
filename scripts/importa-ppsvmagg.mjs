// Importazione automatica nel database dei PPSVMAGG scaricati al mattino dall'SFTP Messaggerie.
// Eseguito da GitHub Actions (.github/workflows/importa-ppsvmagg.yml) verso le 8:00 ora italiana,
// dopo il download automatico (5:30-7:30) della edge function sftp-messaggerie.
//
// Per ogni file scaricato non ancora importato (edge function msg-import-automatico, azione "piano"):
//   1. scarica il file dall'URL firmato e lo legge con leggiPpsvmagg: stessa lettura e stessa
//      somma per giorno × EAN × cliente × fornito/reso × lancio (causale YBA3) del tasto "📥 Importa" di index.html
//   2. lo carica a blocchi con le RPC msg_import_* (tramite la edge function, service role)
//   3. confronta i totali calcolati dal database con quelli del file e scrive l'esito nel registro
//      SFTP di PDE Analisi (sftp_esecuzioni, origine "importazione")
//
// Variabili d'ambiente: MSG_IMPORT_CRON_KEY (segreto GitHub = app_secrets.msg_import_cron),
// FORZA=1 per ignorare il controllo dell'orario (avvio manuale).
// Prova in locale senza database: node scripts/importa-ppsvmagg.mjs --leggi <file PPSVMAGG>
// Nei log stampa solo conteggi di righe (il repo è pubblico): copie e importi vanno nel registro.

import { readFile } from "node:fs/promises";

const FN_URL = "https://tdflwenlylhctxssatax.supabase.co/functions/v1/msg-import-automatico";
const ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRkZmx3ZW5seWxoY3R4c3NhdGF4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYzMzgyNzYsImV4cCI6MjA5MTkxNDI3Nn0.l35qEL7LOvyYuI1McQlVqj4vbyTqmlevcmqWbTGYi2Q";
const CRON_KEY = process.env.MSG_IMPORT_CRON_KEY;
const ORA_INIZIO = 8; // ora italiana
const BLOCCO = 2000;

// ─── Lettura del file: copia di leggiPpsvmagg in index.html (tenerle uguali) ───
const PPSV_LUNGHEZZA = 813;
const campo = (r, a, b) => r.slice(a - 1, b).trim();
const intero = (r, a, b) => {
  const s = campo(r, a, b);
  if (!/^\d+$/.test(s)) throw new Error(`atteso un numero in posizione ${a}-${b}, trovato "${s}"`);
  return Number(s);
};
const data8 = s => `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}`;

function leggiPpsvmagg(testo) {
  const righe = testo.split(/\r?\n/).filter(r => r.length);
  let dataFile = null, dichiarate = null, lette = 0;
  const mov = new Map(), titoli = new Map(), clienti = new Map();
  const tot = { F: { copie: 0, netto: 0 }, R: { copie: 0, netto: 0 } };   // netto in centesimi
  righe.forEach((r, i) => {
    if (r.length !== PPSV_LUNGHEZZA) throw new Error(`riga ${i + 1}: lunga ${r.length} caratteri invece di ${PPSV_LUNGHEZZA}`);
    const tipo = r.slice(0, 4);
    try {
      if (tipo === "MA00") { dataFile = data8(campo(r, 13, 20)); dichiarate = intero(r, 28, 35); return; }
      if (tipo === "MA99") { if (intero(r, 28, 35) !== dichiarate) throw new Error("la coda non coincide con la testata"); return; }
      if (tipo !== "MAMA") throw new Error(`tipo record sconosciuto "${tipo}"`);
      lette++;
      const data = data8(campo(r, 19, 26));
      const ean = campo(r, 276, 288);
      const cliente = campo(r, 39, 46);
      const m = campo(r, 266, 267).charAt(0) === "R" ? "R" : "F";
      const copie = intero(r, 47, 51);
      const prezzo = intero(r, 56, 62);          // centesimi (la pos. 55 a volte vale 1 o 2 sui resi: non fa parte del prezzo)
      const netto = intero(r, 501, 515);         // centesimi
      const lancio = campo(r, 375, 378) === "YBA3";   // bolla di lancio; il resto è rifornimento
      const k = `${data}|${ean}|${cliente}|${m}|${lancio}`;
      const x = mov.get(k) || { data, ean, codice_cliente: cliente, movimento: m, lancio, copie: 0, lordo: 0, netto: 0 };
      x.copie += copie; x.lordo += copie * prezzo; x.netto += netto;
      mov.set(k, x);
      tot[m].copie += copie; tot[m].netto += netto;
      titoli.set(ean, { ean, titolo: campo(r, 311, 370), codice_editore: campo(r, 259, 261).replace(/^0+/, ""),
        collana: campo(r, 289, 294), prezzo_copertina: prezzo / 100 });
      clienti.set(cliente, { codice_cliente: cliente, ragione_sociale: campo(r, 113, 142), indirizzo: campo(r, 143, 172),
        cap: campo(r, 173, 177), citta: campo(r, 178, 198), provincia: campo(r, 199, 200), partita_iva: campo(r, 201, 211) });
    } catch (e) { throw new Error(`riga ${i + 1}: ${e.message}`); }
  });
  // Gli storici scaricati con FileZilla non hanno testata né coda: righe non verificabili, data = ultimo giorno
  if (dichiarate === null && !lette) throw new Error("nessuna riga MA00/MAMA: non sembra un file PPSVMAGG");
  if (dichiarate !== null && lette !== dichiarate) throw new Error(`la testata dichiara ${dichiarate} righe, lette ${lette}`);
  const movimenti = [...mov.values()].map(x => ({ ...x, lordo: x.lordo / 100, netto: x.netto / 100 }));
  if (dataFile === null) dataFile = movimenti.reduce((d, x) => x.data > d ? x.data : d, "");
  return { dataFile, righeFile: lette, movimenti, titoli: [...titoli.values()], clienti: [...clienti.values()], tot };
}

const decodifica = buf => new TextDecoder("windows-1252").decode(buf);
const euro = c => (c / 100).toFixed(2);
const riepilogo = p => `${p.righeFile} righe del file → ${p.movimenti.length} movimenti · fornite ${p.tot.F.copie} copie (${euro(p.tot.F.netto)} €) · rese ${p.tot.R.copie} copie (${euro(p.tot.R.netto)} €)`;

// ─── Chiamate alla edge function ───
async function job(azione, dati = {}) {
  for (let tentativo = 1; ; tentativo++) {
    const res = await fetch(FN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${ANON_KEY}`, "x-cron-key": CRON_KEY },
      body: JSON.stringify({ azione, ...dati }),
    });
    const j = await res.json().catch(() => ({}));
    if (res.ok) return j;
    const msg = `${azione}: ${j.error || res.status}`;
    // Timeout o runtime fermato: le RPC sono idempotenti, si riprova fino a 3 volte
    if (tentativo >= 3 || !(/timeout/i.test(msg) || [502, 503, 504, 546].includes(res.status))) throw new Error(msg);
    await new Promise(r => setTimeout(r, 5000 * tentativo));
  }
}

async function importa(f) {
  const t0 = Date.now();
  const res = await fetch(f.url);
  if (!res.ok) throw new Error(`file non leggibile (${res.status})`);
  const p = leggiPpsvmagg(decodifica(new Uint8Array(await res.arrayBuffer())));

  await job("inizia", { file: f.file, nome_file: f.nome_remoto, data_file: p.dataFile, righe_file: p.righeFile });
  for (let k = 0; k < Math.max(p.titoli.length, p.clienti.length); k += BLOCCO) {
    await job("anagrafiche", { titoli: p.titoli.slice(k, k + BLOCCO), clienti: p.clienti.slice(k, k + BLOCCO) });
  }
  for (let k = 0; k < p.movimenti.length; k += BLOCCO) {
    await job("movimenti", { file: f.file, righe: p.movimenti.slice(k, k + BLOCCO) });
  }
  // Qui solo i totali per il controllo; editori e riepiloghi li aggiorna di notte il database
  // (pg_cron msg-import-chiudi): di giorno, col disco lento, la chiusura bloccava tutto il database
  const db = await job("da-chiudere", { file: f.file });

  // Stesso controllo del tasto "Importa": totali del database = totali del file
  const uguali = db.righe_caricate === p.movimenti.length
    && db.copie_fornite === p.tot.F.copie && db.copie_rese === p.tot.R.copie
    && Math.round(db.netto_fornito * 100) === p.tot.F.netto && Math.round(db.netto_reso * 100) === p.tot.R.netto;
  const testo = `${f.nome_remoto}: ${p.righeFile} righe del file → ${db.righe_caricate} nel database · fornite ${db.copie_fornite} copie (${Number(db.netto_fornito).toFixed(2)} €) · rese ${db.copie_rese} copie (${Number(db.netto_reso).toFixed(2)} €)`
    + (uguali ? "" : ` · ATTENZIONE: il file dice ${p.movimenti.length} movimenti, fornite ${p.tot.F.copie} (${euro(p.tot.F.netto)} €), rese ${p.tot.R.copie} (${euro(p.tot.R.netto)} €)`);
  await job("registra", { ok: uguali, messaggio: `Importato ${testo}` });
  // Nel log pubblico di GitHub solo i conteggi delle righe, niente copie né importi
  console.log(`${uguali ? "OK " : "KO "} ${f.nome_remoto}: ${p.righeFile} righe del file → ${db.righe_caricate} nel database, totali ${uguali ? "uguali al file" : "DIVERSI dal file"} (${Math.round((Date.now() - t0) / 1000)}s)`);
  return uguali;
}

function oraItaliana() {
  return Number(new Intl.DateTimeFormat("it-IT", { timeZone: "Europe/Rome", hour: "2-digit", hourCycle: "h23" }).format(new Date()));
}

// Prova in locale: legge un file e stampa i totali (da confrontare con scripts/leggi_ppsvmagg.py)
if (process.argv[2] === "--leggi") {
  for (const nome of process.argv.slice(3)) console.log(`${nome}: ${riepilogo(leggiPpsvmagg(decodifica(await readFile(nome))))}`);
  process.exit(0);
}

if (!CRON_KEY) { console.error("Manca il segreto MSG_IMPORT_CRON_KEY"); process.exit(1); }
const ora = oraItaliana();
if (!process.env.FORZA && ora < ORA_INIZIO) {
  console.log(`In Italia sono le ${ora}: si parte dalle ${ORA_INIZIO}:00, esco.`);
  process.exit(0);
}

const { file } = await job("piano");
console.log(`Da importare: ${file.length} (${file.map(f => f.nome_remoto).join(", ") || "nessuno"})`);

let errori = 0;
for (const f of file) {
  try {
    if (!(await importa(f))) errori++;
  } catch (e) {
    errori++;
    const msg = e instanceof Error ? e.message : String(e);
    console.log(`ERR ${f.nome_remoto}: ${msg.slice(0, 300)}`);
    await job("registra", { ok: false, messaggio: `Importazione di ${f.nome_remoto} non riuscita: ${msg}` }).catch(() => {});
  }
}
console.log(`Fine: ${file.length - errori} importati, ${errori} con problemi`);
process.exit(errori ? 1 : 0);
