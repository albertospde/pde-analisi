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
| 258 | Codice | 3 | ❓ | una cifra |
| 259-261 | Codice editore Messaggerie | A94 | ✅ | = `codice_editore` di Giro Manager (0000000277 → 277) su 5.838/5.838 righe. Un codice può comprendere più editori PDE (277 = La Nave di Teseo e La Nave dei Piccoli): l'editore si assegna per titolo, vedi sotto |
| 266-267 | Movimento | F1 | ✅ | F = fornito, R = reso (coincide con i documenti di reso) |
| 269-275 | File | PPSV286 | ✅ | |
| 276-288 | EAN | 9788880636809 | ✅ | |
| 289-294 | Collana | STORIA | ✅ | 1 per titolo; NON è l'editore (Adelphi ne ha 24: ADE, PBA, BAD, ...) |
| 297-298 | Codice | 28 | ❓ | legato al cliente: zona / area? |
| 299-304 | Magazzino | ME6021 | 🟡 | |
| 311-370 | Titolo | RAGAZZI VENUTI TERRA ISRAELE | ✅ | |
| 371-374 | Canale ordine | WEB | 🟡 | WEB, ARIA, FTP, MELI |
| 375-378 | Causale magazzino | YBA1 | ✅ | **YBA3 = bolla di lancio** (data ordine = data di iscrizione del lancio: nel 286 i lanci 42 e 43); YBA1 rifornimento; ZRR reso; YURG urgente (MELI). Anche alcune spedizioni di catalogo hanno YBA3 (es. 20-21/05/2025) |
| 379-389 | Campagna | FAZI2026 | 🟡 | quasi sempre vuoto |
| 391-405 | Importo sconto 1 | …433 | ✅ | = copie × prezzo / 1,04 × sconto 1 (34.219/34.222) |
| 406-420 | Importo sconto 2 | …201 | ✅ | stessa formula con sconto 2 |
| 421-435 | Importo sconto 3 | …072 | ✅ | stessa formula con sconto 3 |
| 436-450 | Importo sconto 4 | 0 | 🟡 | sempre 0 nel file analizzato |
| 470-498 | Codici GC/GH/Z | GC00000034GH00000010Z02M00303 | 🟡 | GC = gruppo cliente di Giro Manager (34 Mondadori Franch., 82 Amazon, 2 Feltrinelli Librerie); GH e Z non decodificati |
| 501-515 | Importo netto | …766 | 🟡 | importo riga; circa copie × prezzo × (1 − sconti), formula esatta non ricostruita |
| 524-533 | Numero bolla | 0759657782 | 🟡 | più bolle per documento |
| 803-812 | Numero documento | 0000330751 | 🟡 | |

Le posizioni non elencate sono spazi o zeri fissi.

## Lancio e rifornimento

Ogni movimento è **lancio** (causale di magazzino YBA3) o **rifornimento**. Il rifornimento è **da novità** se il
titolo è uscito da meno di 6 mesi, altrimenti **classico** (`_msg_tipo`). La data di uscita (`msg_titoli.data_uscita`)
è la prima bolla di lancio del titolo, se arriva prima di ogni suo rifornimento (così le spedizioni YBA3 sul catalogo
non rendono novità titoli vecchi), oppure la data di messa in vendita delle novità di Giro Manager. Per i titoli
lanciati prima dello storico caricato le date vengono dai mensili marzo-agosto 2025 (`msg_uscite_storico`, caricata con
`importa_storico.py --uscite`).

## Clienti

Canale, categoria e gruppo cliente vengono da Giro Manager (`anagrafiche_clienti` → `gruppi_clienti` → `canali`),
copiati in `msg_clienti_gruppo` a ogni importazione; i codici cliente si confrontano senza zeri iniziali.

## Editore di un titolo

Il file non contiene il nome dell'editore. PDE Analisi lo assegna a ogni titolo (`_msg_assegna_editori`):
1. editore del titolo in Giro Manager (titoli, titoli manuali, lanci), ricondotto all'anagrafica `ranking_editori`
   (alias di Giro Manager; nomi confrontati senza articoli e "Edizioni/Editore/Srl");
2. scelta a mano della collana (pagina Collane di PDE Analisi, tabella `msg_collane_editore`);
3. editore prevalente fra i titoli noti con stesso codice e stessa collana;
4. editore principale del codice in anagrafica; altrimenti "EDITORE COD. X".

## Controllo su PPSVMAGG.286

Fornito 26.707 righe, 83.503 copie, netto 806.329,73 €. Reso 7.515 righe, 10.345 copie, netto 104.882,31 €.
1.209 clienti, 11.499 titoli, 826 sigle editore.
