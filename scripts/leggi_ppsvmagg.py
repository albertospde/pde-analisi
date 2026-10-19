"""Lettura del file Messaggerie PPSVMAGG.NNN ("Doc. di fornito-reso-Fatt.MELI").

Tracciato RICOSTRUITO dall'analisi dei file (Messaggerie non l'ha fornito): vedi
docs/tracciato-ppsvmagg.md per cosa è verificato e cosa è solo ipotesi.

Uso:  py scripts/leggi_ppsvmagg.py <file>   → controlla il file e stampa i totali
"""
import sys
from collections import Counter

LUNGHEZZA = 813

# (nome, inizio, fine, tipo) con posizioni 1-based inclusive.
# tipo: "t" testo, "i" intero, "e2" importo con 2 decimali impliciti, "d8" data AAAAMMGG, "d6" data AAMMGG
CAMPI = [
    ("tipo_record",          1,   4, "t"),   # MA00 testata, MAMA dettaglio, MA99 coda
    ("anno_documento",       5,   8, "i"),
    ("societa",              9,  10, "t"),   # 60 quasi sempre
    ("tipo_documento",      11,  12, "t"),   # BA bolla, RR reso, FE/FD/FX/RX/RN altri
    ("numero_documento",    13,  18, "t"),
    ("data_documento",      19,  26, "d8"),
    ("codice_articolo",     29,  38, "t"),   # EAN senza le prime 3 cifre
    ("codice_cliente",      39,  46, "t"),   # intestatario: 1:1 con ragione sociale e P.IVA
    ("copie",               47,  51, "i"),
    ("prezzo_copertina",    55,  62, "e2"),  # IVA inclusa, verificato su 80/80 prezzi di Giro Manager
    ("codice_63_64",        63,  64, "t"),   # 01 quasi sempre: significato non noto
    ("sconto_1_perc",       65,  68, "e2"),  # 30,00 tipico
    ("sconto_2_perc",       69,  72, "e2"),
    ("sconto_3_perc",       73,  76, "e2"),
    ("codice_77",           77,  77, "t"),   # L quasi sempre
    ("codice_78_84",        78,  84, "t"),   # fisso per titolo: significato non noto
    ("codice_85_87",        85,  87, "t"),
    ("dilazione_giorni",    89,  91, "i"),   # 060, 090, 120, 360: ipotesi giorni di pagamento
    ("tipo_cliente",        98,  98, "t"),   # C / R / A / spazio
    ("codice_destinatario", 99, 106, "t"),   # punto di consegna
    ("data_ordine",        107, 112, "d6"),  # sempre <= data documento
    ("ragione_sociale",    113, 142, "t"),
    ("indirizzo",          143, 172, "t"),
    ("cap",                173, 177, "t"),
    ("citta",              178, 198, "t"),
    ("provincia",          199, 200, "t"),
    ("partita_iva",        201, 211, "t"),
    ("flag_220",           220, 220, "t"),   # S fornito, C reso
    ("data_competenza",    223, 230, "d8"),  # fine mese (fattura?)
    ("causale",            231, 233, "t"),   # YLF, LR, FE, YRX, ...
    ("riferimento_cliente", 234, 242, "t"),
    ("codice_258",         258, 258, "t"),
    ("codice_editore",     259, 261, "t"),   # codice editore Messaggerie: = Giro Manager su 5.838/5.838 righe
    ("movimento",          266, 267, "t"),   # F1/F0 fornito, R1 reso
    ("file",               269, 275, "t"),   # PPSV + numero file
    ("ean",                276, 288, "t"),
    ("sigla_editore",      289, 294, "t"),   # ADE = Adelphi, ...
    ("codice_297_298",     297, 298, "t"),   # legato al cliente: zona/area?
    ("magazzino",          299, 304, "t"),   # ME6021
    ("titolo",             311, 370, "t"),
    ("canale_ordine",      371, 374, "t"),   # WEB, ARIA, FTP, MELI
    ("causale_magazzino",  375, 378, "t"),   # YBA1, ZRR, ...
    ("campagna",           379, 389, "t"),   # es. FAZI2026
    ("importo_sconto_1",   391, 405, "e2"),  # = copie x prezzo/1,04 x sconto_1 (34.219/34.222 righe)
    ("importo_sconto_2",   406, 420, "e2"),
    ("importo_sconto_3",   421, 435, "e2"),
    ("importo_sconto_4",   436, 450, "e2"),  # sempre 0 nel file analizzato
    ("importo_netto",      501, 515, "e2"),  # importo riga calcolato da Messaggerie
    ("numero_bolla",       524, 533, "t"),
    ("numero_documento_2", 803, 812, "t"),
]


def converti(valore, tipo):
    v = valore.strip()
    if tipo == "t":
        return v
    if not v:
        return None
    if not v.isdigit():
        raise ValueError(f"atteso un numero, trovato {valore!r}")
    if tipo == "i":
        return int(v)
    if tipo == "e2":
        return int(v) / 100
    if tipo == "d8":
        return f"{v[:4]}-{v[4:6]}-{v[6:8]}"
    if tipo == "d6":
        return f"20{v[:2]}-{v[2:4]}-{v[4:6]}"
    raise ValueError(tipo)


def leggi(percorso):
    testata = coda = None
    righe = []
    with open(percorso, encoding="latin-1") as f:
        for n, riga in enumerate(f, 1):
            riga = riga.rstrip("\r\n")
            if len(riga) != LUNGHEZZA:
                raise ValueError(f"riga {n}: lunghezza {len(riga)} invece di {LUNGHEZZA}")
            tipo = riga[:4]
            if tipo == "MA00":
                testata = {"data": converti(riga[12:20], "d8"), "righe": int(riga[27:35])}
            elif tipo == "MA99":
                coda = {"righe": int(riga[27:35])}
            elif tipo == "MAMA":
                try:
                    righe.append({nome: converti(riga[a - 1:b], t) for nome, a, b, t in CAMPI})
                except ValueError as e:
                    raise ValueError(f"riga {n}: {e}") from None
            else:
                raise ValueError(f"riga {n}: tipo record sconosciuto {tipo!r}")
    if testata and testata["righe"] != len(righe):
        raise ValueError(f"la testata dichiara {testata['righe']} righe, lette {len(righe)}")
    if coda and coda["righe"] != len(righe):
        raise ValueError(f"la coda dichiara {coda['righe']} righe, lette {len(righe)}")
    return testata, righe


if __name__ == "__main__":
    testata, righe = leggi(sys.argv[1])
    print(f"File del {testata['data']}: {len(righe)} righe (testata e coda coincidono)")
    for mov in ("F", "R"):
        sel = [r for r in righe if r["movimento"].startswith(mov)]
        print(f"  {'Fornito' if mov == 'F' else 'Reso   '}: {len(sel):6d} righe, "
              f"{sum(r['copie'] for r in sel):7d} copie, "
              f"lordo {sum(r['copie'] * r['prezzo_copertina'] for r in sel):12,.2f} EUR, "
              f"netto {sum(r['importo_netto'] for r in sel):12,.2f} EUR")
    print("  Documenti:", dict(Counter(r["tipo_documento"] for r in righe)))
    print("  Clienti:", len({r["codice_cliente"] for r in righe}), "· Titoli:", len({r["ean"] for r in righe}),
          "· Editori (sigle):", len({r["sigla_editore"] for r in righe}))
    print("  Date ordine dal", min(r["data_ordine"] for r in righe), "al", max(r["data_ordine"] for r in righe))
