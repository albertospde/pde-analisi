# Tracciato PPSVMAGG (ricostruito)

File Messaggerie `PPSVMAGG.NNN` — "Doc. di fornito-reso-Fatt.MELI", cartella SFTP `/Out`.
Messaggerie non ha fornito il tracciato: questo è ricostruito dall'analisi di `PPSVMAGG.286`
(14/10/2026, 34.222 righe) e dal confronto con i dati di Giro Manager. Lettore: `scripts/leggi_ppsvmagg.py`.

## Struttura

- Testo ASCII a **lunghezza fissa**: ogni riga 813 caratteri, fine riga CRLF.
- `MA00` testata: data file (pos. 13-20) e numero righe di dettaglio (28-35).
- `MAMA` una riga per articolo movimentato.
- `MA99` coda: stesso numero righe della testata.
- Numeri senza virgola: importi e percentuali hanno **2 decimali impliciti** (`00001500` = 15,00).

## Campi della riga MAMA

Affidabilità: ✅ verificato con dati esterni o formule su tutte le righe · 🟡 molto probabile · ❓ significato ignoto

| Pos. | Campo | Esempio | | Note |
|---|---|---|---|---|
| 1-4 | Tipo record | MAMA | ✅ | |
| 5-8 | Anno documento | 2026 | ✅ | |
| 9-10 | Società | 60 | 🟡 | 60 quasi sempre, 01 raro |
| 11-12 | Tipo documento | BA | 🟡 | BA bolla (fornito), RR reso, FE/FD/FX/RX/RN rari |
| 13-18 | Numero documento | 330751 | 🟡 | ripetuto in 803-812 |
| 19-26 | Data documento | 20261013 | ✅ | AAAAMMGG |
| 29-38 | Codice articolo | 8880636809 | ✅ | = EAN senza le prime 3 cifre |
| 39-46 | Codice cliente | 01935101 | ✅ | 1:1 con ragione sociale e P.IVA |
| 47-51 | Copie | 00001 | ✅ | sempre positive: il segno lo dà il movimento (F/R) |
| 55-62 | Prezzo di copertina | 00001500 | ✅ | IVA inclusa; 80/80 uguali ai prezzi di Giro Manager |
| 63-64 | Codice | 01 | ❓ | 01 nel 96% delle righe |
| 65-68 | Sconto 1 % | 3000 | ✅ | 30,00% |
| 69-72 | Sconto 2 % | 1400 | ✅ | |
| 73-76 | Sconto 3 % | 0500 | ✅ | |
| 77 | Codice | L | ❓ | |
| 78-84 | Codice articolo | 0000100 | ❓ | fisso per titolo |
| 85-87 | Codice | 006 | ❓ | |
| 89-91 | Dilazione | 090 | 🟡 | 060/090/120/360: giorni di pagamento |
| 98 | Tipo cliente | C | ❓ | C / R / A / spazio |
| 99-106 | Codice destinatario | 7664699 | 🟡 | punto di consegna |
| 107-112 | Data ordine | 261009 | 🟡 | AAMMGG, sempre ≤ data documento |
| 113-142 | Ragione sociale | MF INGROSSO SPA | ✅ | |
| 143-172 | Indirizzo | VIA DEL COMMERCIO, 1 | ✅ | |
| 173-177 | CAP | 20080 | ✅ | |
| 178-198 | Città | CARPIANO | ✅ | |
| 199-200 | Provincia | MI | ✅ | |
| 201-211 | Partita IVA | 02690950403 | ✅ | |
| 220 | Flag | S | 🟡 | S fornito, C reso |
| 223-230 | Data competenza | 20261031 | 🟡 | fine mese: data fattura? |
| 231-233 | Causale | YLF | 🟡 | YLF fornito, LR reso, ... |
| 234-242 | Riferimento cliente | | ❓ | quasi sempre vuoto |
| 258-262 | Codice | 3A94 | ❓ | |
| 266-267 | Movimento | F1 | ✅ | F = fornito, R = reso (coincide con i documenti di reso) |
| 269-275 | File | PPSV286 | ✅ | |
| 276-288 | EAN | 9788880636809 | ✅ | |
| 289-294 | Sigla editore | STORIA | ✅ | 1 per titolo (ADE = Adelphi, ...) |
| 297-298 | Codice | 28 | ❓ | legato al cliente: zona / area? |
| 299-304 | Magazzino | ME6021 | 🟡 | |
| 311-370 | Titolo | RAGAZZI VENUTI TERRA ISRAELE | ✅ | |
| 371-374 | Canale ordine | WEB | 🟡 | WEB, ARIA, FTP, MELI |
| 375-378 | Causale magazzino | YBA1 | 🟡 | |
| 379-389 | Campagna | FAZI2026 | 🟡 | quasi sempre vuoto |
| 391-405 | Importo sconto 1 | …433 | ✅ | = copie × prezzo / 1,04 × sconto 1 (34.219/34.222) |
| 406-420 | Importo sconto 2 | …201 | ✅ | stessa formula con sconto 2 |
| 421-435 | Importo sconto 3 | …072 | ✅ | stessa formula con sconto 3 |
| 436-450 | Importo sconto 4 | 0 | 🟡 | sempre 0 nel file analizzato |
| 470-498 | Codici GC/GH/Z | GC00000034GH00000010Z02M00303 | ❓ | |
| 501-515 | Importo netto | …766 | 🟡 | importo riga; circa copie × prezzo × (1 − sconti), formula esatta non ricostruita |
| 524-533 | Numero bolla | 0759657782 | 🟡 | più bolle per documento |
| 803-812 | Numero documento | 0000330751 | 🟡 | |

Le posizioni non elencate sono spazi o zeri fissi.

## Controllo su PPSVMAGG.286

Fornito 26.707 righe, 83.503 copie, netto 806.329,73 €. Reso 7.515 righe, 10.345 copie, netto 104.882,31 €.
1.209 clienti, 11.499 titoli, 826 sigle editore.
