# STerminal

Ripristino di sessioni e **aree di lavoro** per PowerShell su Windows Terminal.

Risolve il fastidio di partenza: a ogni riavvio i tab tornano vergini. STerminal lavora su due livelli.

## Due livelli

1. **Ripristino nativo di Windows Terminal** (la "fotografia").
   Dalla 1.21 WT sa gia' ricaricare il contenuto dei tab dell'ultima sessione (testo, coi colori). STerminal lo da' per acceso (`firstWindowPreference: persistedWindowLayout`) e aggiunge al profilo PowerShell il report della cartella corrente, cosi' i tab tornano anche nella dir giusta. Copre il caso "riavvio il PC, rivoglio quello che avevo".

2. **Aree di lavoro** (quello che WT *non* fa).
   Gruppi di tab **nominati e selezionabili**: salvi un set (titoli, colori, cartelle, storico) e lo riprendi quando vuoi, da una mini-interfaccia. E' la cosa che a WT manca (feature request #8590, ancora aperta), in stile "aree di lavoro" di Edge.

## Requisiti
- Windows 10/11 con **Windows Terminal 1.21+**
- **Windows PowerShell 5.1** o **PowerShell 7** (entrambe supportate)

## Componenti
- `STerminal.psm1` — il modulo (motore).
- `Show-STerminal.ps1` — la mini-interfaccia (WPF).
- `tests\STerminal.Tests.ps1` — la suite di test.

## Installazione
Il profilo PowerShell 5.1 e' gia' configurato per:
- riportare la cartella corrente a WT (ripristino dir);
- auto-registrare ogni tab WT interattivo (serve alle aree di lavoro).

A comandi: `Import-Module C:\projects\STerminal\STerminal.psm1`
Interfaccia: lancia `Show-STerminal.ps1`, o la scorciatoia "STerminal" nel menu Start.

## Uso

### Mini-interfaccia
`powershell.exe -File C:\projects\STerminal\Show-STerminal.ps1`
Finestra con la lista delle aree: **Riprendi · Salva tab aperti… · Elimina · Aggiorna**.

### A comandi
- `Save-STWorkspace -Name "lavoro"` — salva i tab aperti come area.
- `Resume-STWorkspace -Name "lavoro"` — riapre l'area in una finestra WT dedicata.
- `Get-STWorkspace` — elenca le aree.
- `Remove-STWorkspace -Name "lavoro"` — elimina.
- `Set-STerminalTab -Title "nome" -Color "#1FAA55"` — da' nome/colore al tab corrente (vedi limiti).

## Come funziona (in breve)
Ogni tab si registra (uno "slot" in `~/.sterminal`) e cattura il proprio output con `Start-Transcript`. Un'area = un set di slot salvato in `~/.sterminal/workspaces/<nome>`. Il Resume ricrea i tab con `wt.exe`, **gia' colorati e titolati alla nascita** (cosi' scavalca il bug WT #19970 del focus-jump) e nelle cartelle giuste; il comando passa in base64 (`-EncodedCommand`) per non farsi rompere il quoting da `wt`.

## Limiti onesti
- **Storico = testo.** Lo scrollback torna come testo; i colori ANSI *dentro* l'output vecchio si perdono (`Start-Transcript` li scarta). I colori e i nomi *dei tab* invece tornano.
- **Niente stato vivo.** Variabili, job, processi non sopravvivono: l'area e' fotografia + struttura, non una sessione viva. Il "motore vivo" e' una fase futura.
- **Titolo/colore dei tab:** la shell non puo' *leggere* quelli impostati dalla UI di WT (click destro / doppio click). Usa `Set-STerminalTab` (o l'interfaccia) perche' finiscano nell'area.
- **Una finestra alla volta:** `Save` cattura tutti i tab aperti registrati (pensato per una finestra sola).
- **Non testati:** percorsi di rete (UNC) e path oltre 260 caratteri.

## Test
`powershell.exe -NoProfile -File tests\STerminal.Tests.ps1`
Copre estrazione storico, salvataggio, e i percorsi/titoli difficili (spazi, apostrofi, accenti, cartelle sparite). Gira sia in 5.1 sia in 7.

## Roadmap
- Editor di un'area da zero nell'interfaccia, con **comando per tab** (un tab che all'apertura lancia qualcosa).
- **Fase 2 — motore vivo:** mantenere viva la sessione (variabili/job) tra le riaperture, via named pipe (`Enter-PSHostProcess`).
- Storico a colori (cattura VT).
