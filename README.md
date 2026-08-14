# STerminal

Ripristino di sessioni e **aree di lavoro** per PowerShell su Windows Terminal.

Risolve il fastidio di partenza: a ogni riavvio i tab tornano vergini. STerminal lavora su due livelli.

## Due livelli

1. **Ripristino nativo di Windows Terminal** (la "fotografia").
   Dalla 1.21 WT sa gia' ricaricare il contenuto dei tab dell'ultima sessione (testo, coi colori). STerminal lo da' per acceso (`firstWindowPreference: persistedWindowLayout`) e aggiunge al profilo PowerShell il report della cartella corrente, cosi' i tab tornano anche nella dir giusta. Copre il caso "riavvio il PC, rivoglio quello che avevo".

2. **Aree di lavoro** (quello che WT *non* fa).
   Gruppi di tab **nominati e selezionabili**, ognuno con la sua cartella e, volendo, un **comando da rilanciare** all'apertura. Li definisci, li salvi, li riprendi quando vuoi — da una mini-interfaccia o a comandi. E' la cosa che a WT manca (feature request #8590, ancora aperta), in stile "aree di lavoro" di Edge.

## Requisiti
- Windows 10/11 con **Windows Terminal 1.21+**
- **Windows PowerShell 5.1** o **PowerShell 7** (entrambe supportate)

## Componenti
- `STerminal.psm1` — il modulo (motore).
- `Show-STerminal.ps1` — la mini-interfaccia (WPF).
- `tests\STerminal.Tests.ps1` — la suite di test.

## Installazione
Il profilo PowerShell 5.1 e' configurato per:
- riportare la cartella corrente a WT (ripristino dir);
- auto-registrare ogni tab WT interattivo (serve a salvare i tab nelle aree).

A comandi: `Import-Module C:\projects\STerminal\STerminal.psm1`
Interfaccia: lancia `Show-STerminal.ps1`, o la scorciatoia "STerminal" nel menu Start.

## Uso

### Mini-interfaccia (`Show-STerminal.ps1`)
Due colonne:
- **Aree di lavoro** — la lista delle aree salvate: **Riprendi / Elimina / Aggiorna**.
- **Tab aperti** — tutto cio' che hai aperto adesso (anche i tab occupati: claude, server...), etichettato `path - attivita [pid]`. I tab che **appartengono gia' a un'area** sono colorati **col colore di quell'area** e la riga lo dice (`in: sistema`), cosi' non li riaggiungi per sbaglio; se il riconoscimento e' solo per cartella, la riga lo dichiara (`in: sistema (stessa cartella)` — vedi *Come si riconosce un tab*). Selezioni uno o piu' tab e **Aggiungi a gruppo**: si apre un dialogo dove **scegli l'area da un elenco** (creare e' un gesto separato, «Nuova area»: cosi' un refuso non crea un'area nuova in silenzio) e uno di due modi mutuamente esclusivi:
  - **Automatico** — colori assortiti (distinti) + titoli originali;
  - **Per singola tab** — imposti titolo e colore di ogni tab a mano (menu coi colori).

### A comandi

**Aree:**
- `New-STWorkspace -Name <n> -Tabs @(@{Title;Cwd;Command;Color}...)` — definisce un'area da zero.
- `Save-STWorkspace -Name <n> [-Group <g>]` — cattura i tab aperti registrati (con `-Group`, solo quelli etichettati).
- `Add-STWorkspaceTab -Name <n> -Tabs @(...) [-AutoColor] [-AllowDuplicate]` — aggiunge tab a un'area (la crea se non c'e'); con `-AutoColor` assegna a ogni tab senza colore un colore distinto dalla tavolozza. **E' idempotente**: un tab con la stessa *ricetta* (cartella + shell + comando) di uno gia' presente **non viene riaggiunto**, ne' dall'area ne' dentro lo stesso lotto. Restituisce `{Added, SkippedExact, SkippedRecipe, Total}` — quello che e' successo, non quello che era stato chiesto. Per due tab gemelli voluti: `-AllowDuplicate`.
- `Set-STWorkspaceColor -Name <n> [-Color '#rrggbb']` — il colore **dell'area**, distinto da quello dei singoli tab (che resta per `wt --tabColor` alla riapertura). Senza `-Color` ne sceglie uno non ancora usato dalle altre aree; un colore che WPF non sa leggere viene rifiutato.
- `Resume-STWorkspace -Name <n>` — riapre l'area: una finestra WT coi suoi tab, pre-colorati, nelle cartelle giuste, ognuno che ristampa il suo storico e poi rilancia il suo comando.
- `Get-STWorkspace` / `Remove-STWorkspace -Name <n>`.

**Tab:**
- `Set-STerminalTab -Title <t> -Color <#rrggbb> -Command <cmd> -Group <g>` — imposta i metadati del tab corrente.
- `Get-STLiveTab` — elenca i tab shell aperti (cartella + comando rieseguibile), anche occupati.
- `Get-STOpenSlots` — i tab registrati attualmente aperti.

### Esempio: gruppo "sistema" (un servizio per tab)
```powershell
New-STWorkspace -Name "sistema" -Tabs @(
  @{ Title='ORKAI';   Cwd='C:\projects\context-server'; Command="& 'C:\projects\context-server\start-server.bat'" }
  @{ Title='Caddy';   Cwd='C:\projects\context-server'; Command="& 'C:\projects\context-server\caddy.exe' run --config 'C:\projects\context-server\Caddyfile'" }
  @{ Title='Chatbot'; Cwd='C:\projects\chatbot';        Command="& 'C:\projects\chatbot\.venv\Scripts\python.exe' 'C:\projects\chatbot\main.py'" }
)
Resume-STWorkspace -Name "sistema"
```

### Esempio: raggruppare per attivita' (anche tab nella stessa cartella)
- **Etichetta:** in ogni tab, `Set-STerminalTab -Group "lavoro"`, poi `Save-STWorkspace -Name "lavoro" -Group "lavoro"`.
- **Oppure dalla UI:** seleziona i tab aperti nella colonna destra e "Aggiungi a gruppo".

## Come si riconosce un tab gia' in un'area

Non esiste un'etichetta che leghi un tab aperto a una voce salvata: il pid cambia a ogni
riavvio, e il titolo lo puoi riscrivere tu. Il riconoscimento avviene per confronto, e ha
**due gradi, entrambi dichiarati nella riga**:

| grado | come | in lista |
|---|---|---|
| **ricetta** | cartella + shell + comando, normalizzati | `in: sistema` |
| **cartella** | solo la cartella coincide | `in: sistema (stessa cartella)` |

Il secondo esiste perche' un'area salvata mesi fa puo' avere i comandi scritti in un modo
e i processi vivi in un altro — per esempio con gli argomenti fra apici — o perche' il
processo vero non e' quello salvato (un `.bat` gira dentro `cmd.exe`). Senza il ripiego,
di sei tab di un'area se ne riconoscerebbe uno.

**Limiti da conoscere:** il grado «cartella» e' largo — due tab aperti nella stessa
cartella risultano entrambi «gia' li'». E' voluto: per non riaggiungere un doppione, un
avviso in piu' costa meno di un riconoscimento mancato. Le virgolette negli argomenti
**non** vengono normalizzate, di proposito: fondere due comandi che non sono lo stesso
sarebbe peggio. Un'identita' certa richiederebbe un identificatore stabile scritto
nell'area e riportato al ripristino: non c'e' ancora.

## Come funziona (in breve)
Ogni tab si registra (uno "slot" in `~/.sterminal`) e cattura il proprio output con `Start-Transcript`. Un'area = un set di tab in `~/.sterminal/workspaces/<nome>`. Il Resume ricrea i tab con `wt.exe`, **gia' colorati e titolati alla nascita** (cosi' scavalca il bug WT #19970 del focus-jump) e nelle cartelle giuste; il comando passa in base64 (`-EncodedCommand`) per non farsi rompere il quoting da `wt`. Per la lista dei tab aperti, `Get-STLiveTab` scandisce l'albero dei processi e legge la cartella corrente di ciascuno dal PEB — cosi' vede anche i tab occupati o non registrati.

## Limiti onesti
- **Storico = testo.** Lo scrollback torna come testo; i colori ANSI *dentro* l'output vecchio si perdono (`Start-Transcript` li scarta). Colori e nomi *dei tab* invece tornano.
- **Niente stato vivo.** Variabili, job, processi non sopravvivono: l'area e' fotografia + struttura + comando, non una sessione viva. Il "motore vivo" e' una fase futura.
- **Niente identificativo di finestra.** WT usa un processo unico per tutte le finestre e `WT_SESSION` e' per-tab: la shell non sa in quale finestra sta. Per questo si raggruppa **per etichetta/selezione**, non "per finestra".
- **Titolo/colore dei tab:** la shell non puo' leggere quelli impostati dalla UI di WT (click destro / doppio click). Usali via `Set-STerminalTab` o l'interfaccia.
- **`claude --resume` catturato e' "secco":** piu' tab claude nella stessa cartella, riaperti, collassano sull'ultima sessione. Per separarli serve l'ID sessione (`claude --resume <id>`).
- **Resume di un'area di servizi li *riavvia*** (conflitti se gia' in esecuzione).
- **Il riconoscimento «stessa cartella» e' un'approssimazione**, non un'identita': vedi *Come si riconosce un tab gia' in un'area*.
- **Non testati:** percorsi di rete (UNC) e path oltre 260 caratteri.

## Test
`powershell.exe -NoProfile -File tests\STerminal.Tests.ps1`
Copre: estrazione storico, salvataggio, percorsi/titoli difficili (spazi, apostrofi, accenti, cartelle sparite), comando per tab, filtro per gruppo, gli helper dei tab vivi, la deduplicazione e la firma delle ricette, il colore delle aree e il riconoscimento dei tab. Lancia anche le prove della mini-interfaccia (`Show-STerminal.ps1 -TestAddDialog`), che pilotano davvero i controlli WPF. Gira sia in 5.1 sia in 7.

Il banco **verifica il proprio isolamento** e si rifiuta di partire se non regge: senza quel controllo, un'esecuzione con il modulo caricato sotto un altro nome scriverebbe nelle aree vere.

## Roadmap
- Chat claude distinte nella stessa cartella via `claude --resume <session-id>`.
- Storico a colori (cattura VT).
- **Fase 2 — motore vivo:** mantenere viva la sessione (variabili/job) tra le riaperture, via named pipe (`Enter-PSHostProcess`).
- Editor nella UI per rinominare/ricolorare/riordinare i tab di un'area.
