// btrfs-migrate CLI: Bubble Tea v2 wizard that collects user input and
// invokes scripts/btrfs-migrate.sh with the chosen flags.
//
// The bash script is the canonical implementation. This wizard is a
// convenience layer — everything it does, you can do by running the
// script directly with flags.
package main

import (
	"flag"
	"fmt"
	"image/color"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"charm.land/bubbles/v2/help"
	"charm.land/bubbles/v2/key"
	"charm.land/bubbles/v2/list"
	"charm.land/bubbles/v2/progress"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

// -- Palette -----------------------------------------------------------------
// Dracula-adjacent on dark terminals, inverted pairings on light. We
// resolve the actual colours lazily so the terminal's detected
// background controls which pair we pick (see tea.BackgroundColorMsg
// handling in Update — it sets hasDark and rebuilds styles()).
type palette struct {
	brand   color.Color
	accent  color.Color
	success color.Color
	warning color.Color
	danger  color.Color
	muted   color.Color
	border  color.Color
	fg      color.Color
	titleBG color.Color
	titleFG color.Color
}

func newPalette(isDark bool) palette {
	pick := lipgloss.LightDark(isDark)
	return palette{
		brand:   pick(lipgloss.Color("#7D56F4"), lipgloss.Color("#BD93F9")),
		accent:  pick(lipgloss.Color("#FF6AC1"), lipgloss.Color("#FF79C6")),
		success: pick(lipgloss.Color("#02BA84"), lipgloss.Color("#50FA7B")),
		warning: pick(lipgloss.Color("#D87C00"), lipgloss.Color("#FFB86C")),
		danger:  pick(lipgloss.Color("#D7263D"), lipgloss.Color("#FF5555")),
		muted:   pick(lipgloss.Color("#6C6F85"), lipgloss.Color("#7B7F9E")),
		border:  pick(lipgloss.Color("#B0B4C8"), lipgloss.Color("#44475A")),
		fg:      pick(lipgloss.Color("#282A36"), lipgloss.Color("#F8F8F2")),
		titleBG: pick(lipgloss.Color("#7D56F4"), lipgloss.Color("#BD93F9")),
		titleFG: pick(lipgloss.Color("#FFFFFF"), lipgloss.Color("#1E1F29")),
	}
}

// styles holds every lipgloss.Style the wizard draws with. Rebuilt
// whenever the palette changes (background detection, resize, etc).
type styles struct {
	title       lipgloss.Style
	header      lipgloss.Style
	muted       lipgloss.Style
	field       lipgloss.Style
	warn        lipgloss.Style
	danger      lipgloss.Style
	success     lipgloss.Style
	panel       lipgloss.Style
	keyKey      lipgloss.Style
	keyVal      lipgloss.Style
	helpBar     lipgloss.Style
	listTitle   lipgloss.Style
	cursor      lipgloss.Style
	prompt      lipgloss.Style
	textFocused lipgloss.Style
	placeholder lipgloss.Style
}

func newStyles(p palette) styles {
	return styles{
		title: lipgloss.NewStyle().
			Bold(true).
			Foreground(p.titleFG).
			Background(p.titleBG).
			Padding(0, 2),
		header: lipgloss.NewStyle().
			Bold(true).
			Foreground(p.accent).
			MarginBottom(1),
		muted: lipgloss.NewStyle().Foreground(p.muted),
		field: lipgloss.NewStyle().Foreground(p.muted),
		warn:  lipgloss.NewStyle().Foreground(p.warning).Bold(true),
		danger: lipgloss.NewStyle().
			Foreground(p.danger).
			Bold(true),
		success: lipgloss.NewStyle().Foreground(p.success).Bold(true),
		panel: lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(p.border).
			Padding(1, 2).
			MarginTop(1),
		keyKey:      lipgloss.NewStyle().Foreground(p.brand).Bold(true),
		keyVal:      lipgloss.NewStyle().Foreground(p.fg),
		helpBar:     lipgloss.NewStyle().Foreground(p.muted).MarginTop(1),
		listTitle:   lipgloss.NewStyle().Foreground(p.brand).Bold(true).MarginBottom(1),
		cursor:      lipgloss.NewStyle().Foreground(p.accent).Bold(true),
		prompt:      lipgloss.NewStyle().Foreground(p.accent),
		textFocused: lipgloss.NewStyle().Foreground(p.fg),
		placeholder: lipgloss.NewStyle().Foreground(p.muted).Italic(true),
	}
}

const Version = "v0.1.0"

// scriptSource holds the resolved path to the bash entrypoint plus an
// optional cleanup closure (non-nil only when we extracted the embedded
// copy to a tempdir). Cleanup is always safe to call.
type scriptSource struct {
	Path    string
	Cleanup func()
}

// locateScript resolves the bash entrypoint. Preference order:
//  1. BTRFS_MIGRATE_SCRIPT env var (explicit override).
//  2. <exe-dir>/scripts/btrfs-migrate.sh (dev checkout sibling).
//  3. <cwd>/scripts/btrfs-migrate.sh (repo root invocation).
//  4. /usr/local/share, /usr/share (packaged install).
//  5. Embedded copy extracted to a tempdir (standalone binary).
func locateScript() (scriptSource, error) {
	noop := func() {}
	if p := os.Getenv("BTRFS_MIGRATE_SCRIPT"); p != "" {
		return scriptSource{Path: p, Cleanup: noop}, nil
	}
	if exe, err := os.Executable(); err == nil {
		cand := filepath.Join(filepath.Dir(exe), "scripts", "btrfs-migrate.sh")
		if _, err := os.Stat(cand); err == nil {
			abs, _ := filepath.Abs(cand)
			return scriptSource{Path: abs, Cleanup: noop}, nil
		}
	}
	if cwd, err := os.Getwd(); err == nil {
		cand := filepath.Join(cwd, "scripts", "btrfs-migrate.sh")
		if _, err := os.Stat(cand); err == nil {
			return scriptSource{Path: cand, Cleanup: noop}, nil
		}
	}
	for _, p := range []string{
		"/usr/local/share/btrfs-migrate/btrfs-migrate.sh",
		"/usr/share/btrfs-migrate/btrfs-migrate.sh",
	} {
		if _, err := os.Stat(p); err == nil {
			return scriptSource{Path: p, Cleanup: noop}, nil
		}
	}
	ex, err := extractScripts()
	if err != nil {
		return scriptSource{}, fmt.Errorf("extract embedded scripts: %w", err)
	}
	return scriptSource{Path: ex.Path, Cleanup: ex.Cleanup}, nil
}

// findScript is a convenience shim for callers that only need the
// path (preview/intro screens). Any tempdir produced by fallback
// extraction is leaked — the OS cleans it at reboot. Use locateScript
// when the caller actually runs the script and can honour Cleanup.
func findScript() (string, error) {
	s, err := locateScript()
	if err != nil {
		return "", err
	}
	return s.Path, nil
}

type plan struct {
	RootDev        string
	BootDev        string
	EfiDev         string
	SepHomeDev     string
	BiosDisk       string
	User           string
	Subvols        string
	Encrypt        string
	LuksKeyFile    string
	EncryptBoot    bool
	Bootloader     string
	InstallBoot    bool
	Snapper        bool
	SnapperHome    bool
	Timeshift      bool
	GrubBtrfs      bool
	BtrfsAssistant bool
	ConvertHome    bool
	MountOpts      string
	DryRun         bool
	ForceInstalled bool
	HaveBackups    bool
	Yes            bool
}

func (p plan) toArgs() []string {
	var a []string
	add := func(flag, val string) {
		if val != "" {
			a = append(a, flag, val)
		}
	}
	addBool := func(flag string, v bool) {
		if v {
			a = append(a, flag)
		}
	}
	add("--root", p.RootDev)
	add("--boot", p.BootDev)
	add("--efi", p.EfiDev)
	add("--sep-home", p.SepHomeDev)
	add("--bios-disk", p.BiosDisk)
	add("--user", p.User)
	add("--subvols", p.Subvols)
	if p.Encrypt != "" && p.Encrypt != "none" {
		a = append(a, "--encrypt", p.Encrypt)
	}
	add("--luks-key-file", p.LuksKeyFile)
	addBool("--encrypt-boot", p.EncryptBoot)
	add("--bootloader", p.Bootloader)
	addBool("--install-bootloader", p.InstallBoot)
	addBool("--snapper", p.Snapper)
	addBool("--snapper-home", p.SnapperHome)
	addBool("--timeshift", p.Timeshift)
	addBool("--grub-btrfs", p.GrubBtrfs)
	addBool("--btrfs-assistant", p.BtrfsAssistant)
	addBool("--convert-home", p.ConvertHome)
	add("--mount-opts", p.MountOpts)
	addBool("--dry-run", p.DryRun)
	addBool("--force-installed", p.ForceInstalled)
	addBool("--i-have-backups", p.HaveBackups)
	addBool("--yes", p.Yes)
	return a
}

type stepID int

const (
	stepIntro stepID = iota
	stepRoot
	stepBoot
	stepEfi
	stepSepHome
	stepBiosDisk
	stepUser
	stepSubvols
	stepEncrypt
	stepLuksKeyFile
	stepEncryptBoot
	stepBootloader
	stepInstallBoot
	stepMountOpts
	stepSnapshots
	stepGrubBtrfs
	stepConvertHome
	stepSafety
	stepReview
	stepDone
)

// stepMeta gives each step a title and a one-line hint for the header.
type stepMeta struct {
	title string
	hint  string
}

// stepOrder lists the visible steps in wizard order — used for the
// progress indicator and for computing step numbers ("2/14").
var stepOrder = []stepID{
	stepIntro, stepRoot, stepBoot, stepEfi, stepSepHome, stepBiosDisk,
	stepUser, stepSubvols, stepEncrypt, stepLuksKeyFile, stepEncryptBoot,
	stepBootloader, stepInstallBoot, stepMountOpts, stepSnapshots,
	stepGrubBtrfs, stepConvertHome, stepSafety, stepReview, stepDone,
}

var stepMetaFor = map[stepID]stepMeta{
	stepIntro:       {"Welcome", "Read the warning, then press Enter to begin."},
	stepRoot:        {"Target root partition", "The block device that will become your new Btrfs /."},
	stepBoot:        {"/boot partition", "A separate ext4 partition that holds the kernel + initramfs."},
	stepEfi:         {"EFI partition", "UEFI system partition (vfat). Leave blank for legacy BIOS."},
	stepSepHome:     {"Separate /home partition", "Optional — only fill this if /home is already on its own partition."},
	stepBiosDisk:    {"BIOS boot disk", "Whole disk for grub-install on BIOS/MBR systems. UEFI users skip."},
	stepUser:        {"Primary user", "Used to repair /home/<name> ownership (issue #2 fix)."},
	stepSubvols:     {"Subvolume layout", "Comma-separated list. Empty keeps the upstream default set."},
	stepEncrypt:     {"Encryption mode", "Encryption is only offered for EMPTY target partitions."},
	stepLuksKeyFile: {"LUKS keyfile", "A 0600 file read by cryptsetup — enables fully non-interactive runs."},
	stepEncryptBoot: {"Encrypt /boot?", "GRUB only. systemd-boot cannot prompt for /boot passphrases."},
	stepBootloader:  {"Bootloader", "GRUB or systemd-boot. Both installed-or-configure-only."},
	stepInstallBoot: {"Install or configure?", "Configure-only just refreshes grub.cfg / bootctl update."},
	stepMountOpts:   {"Mount options", "safe = compress=zstd; perf also opts into zstd:3 + ssd on SSDs."},
	stepSnapshots:   {"Snapshot tooling", "Snapper XOR Timeshift (they conflict). Pick one or none."},
	stepGrubBtrfs:   {"grub-btrfs", "Automatic snapshot boot entries in the GRUB menu."},
	stepConvertHome: {"Convert separate /home?", "Reformat the existing /home partition to Btrfs."},
	stepSafety:      {"Safety gates", "Plan-only OR confirm you have backups + accept destruction."},
	stepReview:      {"Review & run", "Inspect the computed flag set, then run or quit."},
	stepDone:        {"Done", "The script has returned."},
}

// keybindings for the help footer.
type keymap struct {
	Next    key.Binding
	Prev    key.Binding
	Up      key.Binding
	Down    key.Binding
	Quit    key.Binding
	Confirm key.Binding
}

func (k keymap) ShortHelp() []key.Binding {
	return []key.Binding{k.Up, k.Down, k.Next, k.Prev, k.Quit}
}
func (k keymap) FullHelp() [][]key.Binding {
	return [][]key.Binding{
		{k.Up, k.Down},
		{k.Next, k.Prev, k.Confirm},
		{k.Quit},
	}
}

var keys = keymap{
	Up:      key.NewBinding(key.WithKeys("up", "k"), key.WithHelp("↑/k", "up")),
	Down:    key.NewBinding(key.WithKeys("down", "j"), key.WithHelp("↓/j", "down")),
	Next:    key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "next")),
	Prev:    key.NewBinding(key.WithKeys("shift+tab", "alt+left"), key.WithHelp("shift+tab", "back")),
	Confirm: key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "confirm")),
	Quit:    key.NewBinding(key.WithKeys("ctrl+c", "esc"), key.WithHelp("esc", "quit")),
}

type wizard struct {
	step     stepID
	history  []stepID // for Back
	plan     plan
	input    textinput.Model
	choice   list.Model
	progress progress.Model
	help     help.Model
	pal      palette
	st       styles
	isDark   bool
	width    int
	height   int
	err      error
}

type simpleItem struct{ title, desc string }

func (s simpleItem) FilterValue() string { return s.title }
func (s simpleItem) Title() string       { return s.title }
func (s simpleItem) Description() string { return s.desc }

type simpleDelegate struct{ st *styles }

func (d simpleDelegate) Height() int                             { return 2 }
func (d simpleDelegate) Spacing() int                            { return 1 }
func (d simpleDelegate) Update(_ tea.Msg, _ *list.Model) tea.Cmd { return nil }
func (d simpleDelegate) Render(w io.Writer, m list.Model, index int, it list.Item) {
	s, _ := it.(simpleItem)
	selected := index == m.Index()

	cursor := "  "
	titleStyle := d.st.keyVal
	descStyle := d.st.muted
	if selected {
		cursor = d.st.cursor.Render("❯ ")
		titleStyle = lipgloss.NewStyle().
			Foreground(d.st.cursor.GetForeground()).
			Bold(true)
		descStyle = lipgloss.NewStyle().Foreground(d.st.keyKey.GetForeground())
	}
	fmt.Fprintf(w, "%s%s\n    %s",
		cursor,
		titleStyle.Render(s.title),
		descStyle.Render(s.desc),
	)
}

func newWizard(initial plan) *wizard {
	// Start assuming dark background; Update will flip this the moment
	// tea emits a BackgroundColorMsg (near-instant after Program.Run).
	pal := newPalette(true)
	st := newStyles(pal)

	ti := textinput.New()
	ti.Prompt = "❯ "
	ti.CharLimit = 128
	ti.SetWidth(60)
	ti.SetStyles(textinput.Styles{
		Focused: textinput.StyleState{
			Prompt:      st.prompt,
			Text:        st.textFocused,
			Placeholder: st.placeholder,
		},
		Blurred: textinput.StyleState{
			Prompt:      st.muted,
			Text:        st.muted,
			Placeholder: st.placeholder,
		},
	})

	pb := progress.New(
		progress.WithWidth(40),
		progress.WithColors(pal.brand, pal.accent),
	)

	hp := help.New()
	hp.Styles.ShortKey = st.keyKey
	hp.Styles.ShortDesc = st.muted
	hp.Styles.ShortSeparator = st.muted
	hp.Styles.FullKey = hp.Styles.ShortKey
	hp.Styles.FullDesc = hp.Styles.ShortDesc
	hp.Styles.FullSeparator = hp.Styles.ShortSeparator

	w := &wizard{
		step:     stepIntro,
		plan:     initial,
		input:    ti,
		progress: pb,
		help:     hp,
		pal:      pal,
		st:       st,
		isDark:   true,
	}
	return w
}

func (w *wizard) setChoices(title string, items []simpleItem) {
	var li []list.Item
	for _, it := range items {
		li = append(li, it)
	}
	height := len(items)*3 + 2
	l := list.New(li, simpleDelegate{st: &w.st}, 70, height)
	l.Title = title
	l.Styles.Title = w.st.listTitle
	l.SetShowStatusBar(false)
	l.SetFilteringEnabled(false)
	l.SetShowHelp(false)
	l.SetShowTitle(false)
	w.choice = l
}

// refreshStyles regenerates style caches after a palette change.
func (w *wizard) refreshStyles() {
	w.st = newStyles(w.pal)
	w.input.SetStyles(textinput.Styles{
		Focused: textinput.StyleState{
			Prompt:      w.st.prompt,
			Text:        w.st.textFocused,
			Placeholder: w.st.placeholder,
		},
		Blurred: textinput.StyleState{
			Prompt:      w.st.muted,
			Text:        w.st.muted,
			Placeholder: w.st.placeholder,
		},
	})
	w.help.Styles.ShortKey = w.st.keyKey
	w.help.Styles.ShortDesc = w.st.muted
	w.help.Styles.ShortSeparator = w.st.muted
	w.help.Styles.FullKey = w.st.keyKey
	w.help.Styles.FullDesc = w.st.muted
	w.help.Styles.FullSeparator = w.st.muted
}

// stepIndex returns the 1-based position of the current step in
// stepOrder (for the progress indicator).
func (w *wizard) stepIndex() int {
	for i, s := range stepOrder {
		if s == w.step {
			return i + 1
		}
	}
	return 1
}

func (w *wizard) Init() tea.Cmd { return textinput.Blink }

func (w *wizard) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch m := msg.(type) {
	case tea.BackgroundColorMsg:
		w.isDark = m.IsDark()
		w.pal = newPalette(w.isDark)
		w.refreshStyles()
	case tea.WindowSizeMsg:
		w.width = m.Width
		w.height = m.Height
		progWidth := m.Width - 20
		if progWidth > 80 {
			progWidth = 80
		} else if progWidth < 20 {
			progWidth = 20
		}
		w.progress = progress.New(
			progress.WithWidth(progWidth),
			progress.WithColors(w.pal.brand, w.pal.accent),
		)
		w.help.SetWidth(m.Width)
	case tea.KeyPressMsg:
		switch {
		case key.Matches(m, keys.Quit):
			return w, tea.Quit
		case key.Matches(m, keys.Prev):
			if len(w.history) > 0 {
				w.step = w.history[len(w.history)-1]
				w.history = w.history[:len(w.history)-1]
				w.restoreStep()
			}
			return w, nil
		case key.Matches(m, keys.Next):
			return w.advance()
		}
	}
	var cmd tea.Cmd
	switch w.step {
	case stepRoot, stepBoot, stepEfi, stepSepHome, stepBiosDisk,
		stepUser, stepSubvols, stepLuksKeyFile:
		w.input, cmd = w.input.Update(msg)
	case stepEncrypt, stepEncryptBoot, stepBootloader, stepInstallBoot,
		stepMountOpts, stepSnapshots, stepGrubBtrfs, stepConvertHome,
		stepSafety, stepIntro, stepReview:
		w.choice, cmd = w.choice.Update(msg)
	}
	return w, cmd
}

// restoreStep re-wires the textinput/choice widgets when the user
// navigates Back. Ensures placeholder + value reflect the plan state.
func (w *wizard) restoreStep() {
	// Textinput-bearing steps need their current plan value reapplied.
	setInput := func(val, placeholder string) {
		w.input.SetValue(val)
		w.input.Placeholder = placeholder
		w.input.Focus()
	}
	switch w.step {
	case stepRoot:
		setInput(w.plan.RootDev, "/dev/sda3")
	case stepBoot:
		setInput(w.plan.BootDev, "/dev/sda2")
	case stepEfi:
		setInput(w.plan.EfiDev, "/dev/sda1 (blank if BIOS)")
	case stepSepHome:
		setInput(w.plan.SepHomeDev, "blank if /home is on root, else /dev/sdaN")
	case stepBiosDisk:
		setInput(w.plan.BiosDisk, "blank for UEFI, else /dev/sda")
	case stepUser:
		setInput(w.plan.User, "e.g. alice")
	case stepSubvols:
		setInput(w.plan.Subvols, "blank for upstream default set")
	case stepLuksKeyFile:
		setInput(w.plan.LuksKeyFile, "blank to prompt interactively, else path to 0600 keyfile")
	case stepEncrypt:
		w.setChoices("Encryption", []simpleItem{
			{title: "none", desc: "No encryption."},
			{title: "luks", desc: "LUKS2 on the root partition (must be empty)."},
			{title: "lvm-luks", desc: "LVM inside LUKS2 (must be empty)."},
		})
	case stepEncryptBoot:
		w.setChoices("Encrypt /boot?", []simpleItem{
			{title: "no", desc: "Leave /boot unencrypted."},
			{title: "yes", desc: "GRUB only."},
		})
	case stepBootloader:
		items := []simpleItem{
			{title: "grub", desc: "GRUB 2."},
			{title: "systemd-boot", desc: "systemd-boot."},
		}
		if w.plan.EncryptBoot {
			items = items[:1]
		}
		w.setChoices("Bootloader", items)
	case stepInstallBoot:
		w.setChoices("Install bootloader or configure only?", []simpleItem{
			{title: "configure-only", desc: "Regenerate grub.cfg / bootctl update only."},
			{title: "install", desc: "Run grub-install / bootctl install AND configure."},
		})
	case stepMountOpts:
		w.setChoices("Mount options", []simpleItem{
			{title: "safe", desc: "defaults,noatime,compress=zstd."},
			{title: "perf", desc: "defaults,noatime,compress=zstd:3 (+ssd on SSDs)."},
		})
	case stepSnapshots:
		w.setChoices("Snapshot tooling", []simpleItem{
			{title: "none", desc: "Skip."},
			{title: "snapper", desc: "Snapper for /."},
			{title: "snapper+home", desc: "Snapper for / and /home."},
			{title: "timeshift", desc: "Timeshift."},
		})
	case stepGrubBtrfs:
		w.setChoices("grub-btrfs integration?", []simpleItem{
			{title: "no", desc: "Skip."},
			{title: "yes", desc: "Install grub-btrfs."},
		})
	case stepConvertHome:
		w.setChoices("Convert separate /home to Btrfs?", []simpleItem{
			{title: "no", desc: "Leave as-is."},
			{title: "yes", desc: "Reformat to Btrfs."},
		})
	case stepSafety:
		w.setChoices("Safety gates", []simpleItem{
			{title: "plan", desc: "Print the plan only (--dry-run)."},
			{title: "execute", desc: "I have backups."},
			{title: "execute (--force-installed)", desc: "Allow installed system."},
		})
	case stepReview:
		w.setChoices("Ready?", []simpleItem{
			{title: "review", desc: "btrfs-migrate.sh " + strings.Join(w.plan.toArgs(), " ")},
			{title: "run", desc: "Invoke the bash script now (will prompt for sudo)."},
			{title: "quit", desc: "Exit without running anything."},
		})
	}
}

// recordAdvance pushes the *current* step onto history before we
// overwrite w.step with the next one. Call this at the top of every
// case in advance() before the w.step = ... assignment.
func (w *wizard) recordAdvance() {
	w.history = append(w.history, w.step)
}

func (w *wizard) advance() (tea.Model, tea.Cmd) {
	switch w.step {
	case stepIntro:
		w.recordAdvance()
		w.step = stepRoot
		w.input.Placeholder = "/dev/sda3"
		w.input.SetValue(w.plan.RootDev)
		w.input.Focus()
	case stepRoot:
		w.plan.RootDev = strings.TrimSpace(w.input.Value())
		w.recordAdvance()
		w.step = stepBoot
		w.input.SetValue(w.plan.BootDev)
		w.input.Placeholder = "/dev/sda2"
	case stepBoot:
		w.plan.BootDev = strings.TrimSpace(w.input.Value())
		w.recordAdvance()
		w.step = stepEfi
		w.input.SetValue(w.plan.EfiDev)
		w.input.Placeholder = "/dev/sda1 (blank if BIOS)"
	case stepEfi:
		w.plan.EfiDev = strings.TrimSpace(w.input.Value())
		w.recordAdvance()
		w.step = stepSepHome
		w.input.SetValue(w.plan.SepHomeDev)
		w.input.Placeholder = "blank if /home is on root, else /dev/sdaN"
	case stepSepHome:
		w.plan.SepHomeDev = strings.TrimSpace(w.input.Value())
		w.recordAdvance()
		w.step = stepBiosDisk
		w.input.SetValue(w.plan.BiosDisk)
		w.input.Placeholder = "blank for UEFI, else /dev/sda"
	case stepBiosDisk:
		w.plan.BiosDisk = strings.TrimSpace(w.input.Value())
		w.recordAdvance()
		w.step = stepUser
		w.input.SetValue(w.plan.User)
		w.input.Placeholder = "e.g. alice"
	case stepUser:
		w.plan.User = strings.TrimSpace(w.input.Value())
		w.recordAdvance()
		w.step = stepSubvols
		w.input.SetValue(w.plan.Subvols)
		w.input.Placeholder = "blank for upstream default set"
		w.input.CharLimit = 512
	case stepSubvols:
		w.plan.Subvols = strings.TrimSpace(w.input.Value())
		w.input.CharLimit = 128
		w.recordAdvance()
		w.step = stepEncrypt
		w.setChoices("Encryption", []simpleItem{
			{title: "none", desc: "No encryption."},
			{title: "luks", desc: "LUKS2 on the root partition (must be empty)."},
			{title: "lvm-luks", desc: "LVM inside LUKS2 (must be empty)."},
		})
	case stepEncrypt:
		w.plan.Encrypt = w.choice.SelectedItem().(simpleItem).title
		w.recordAdvance()
		if w.plan.Encrypt == "none" {
			w.plan.LuksKeyFile = ""
			w.plan.EncryptBoot = false
			w.step = stepBootloader
			w.setChoices("Bootloader", []simpleItem{
				{title: "grub", desc: "GRUB 2. Supports encrypted /boot. Default."},
				{title: "systemd-boot", desc: "systemd-boot. Incompatible with encrypted /boot."},
			})
		} else {
			w.step = stepLuksKeyFile
			w.input.SetValue(w.plan.LuksKeyFile)
			w.input.Placeholder = "blank to prompt interactively, else path to 0600 keyfile"
		}
	case stepLuksKeyFile:
		w.plan.LuksKeyFile = strings.TrimSpace(w.input.Value())
		w.recordAdvance()
		w.step = stepEncryptBoot
		w.setChoices("Encrypt /boot?", []simpleItem{
			{title: "no", desc: "Leave /boot unencrypted (compatible with systemd-boot)."},
			{title: "yes", desc: "Encrypt /boot too — GRUB only."},
		})
	case stepEncryptBoot:
		w.plan.EncryptBoot = w.choice.SelectedItem().(simpleItem).title == "yes"
		w.recordAdvance()
		w.step = stepBootloader
		items := []simpleItem{
			{title: "grub", desc: "GRUB 2. Supports encrypted /boot. Default."},
			{title: "systemd-boot", desc: "systemd-boot. Incompatible with encrypted /boot."},
		}
		if w.plan.EncryptBoot {
			items = items[:1] // systemd-boot can't do encrypted /boot
		}
		w.setChoices("Bootloader", items)
	case stepBootloader:
		w.plan.Bootloader = w.choice.SelectedItem().(simpleItem).title
		w.recordAdvance()
		w.step = stepInstallBoot
		w.setChoices("Install bootloader or configure only?", []simpleItem{
			{title: "configure-only", desc: "Regenerate grub.cfg / bootctl update only."},
			{title: "install", desc: "Run grub-install / bootctl install AND configure."},
		})
	case stepInstallBoot:
		w.plan.InstallBoot = w.choice.SelectedItem().(simpleItem).title == "install"
		w.recordAdvance()
		w.step = stepMountOpts
		w.setChoices("Mount options", []simpleItem{
			{title: "safe", desc: "defaults,noatime,compress=zstd."},
			{title: "perf", desc: "defaults,noatime,compress=zstd:3 (+ssd on SSDs)."},
		})
	case stepMountOpts:
		w.plan.MountOpts = w.choice.SelectedItem().(simpleItem).title
		w.recordAdvance()
		w.step = stepSnapshots
		w.setChoices("Snapshot tooling", []simpleItem{
			{title: "none", desc: "Skip snapshot integration."},
			{title: "snapper", desc: "Snapper for /."},
			{title: "snapper+home", desc: "Snapper for / and /home."},
			{title: "timeshift", desc: "Timeshift."},
		})
	case stepSnapshots:
		switch w.choice.SelectedItem().(simpleItem).title {
		case "snapper":
			w.plan.Snapper = true
		case "snapper+home":
			w.plan.Snapper = true
			w.plan.SnapperHome = true
		case "timeshift":
			w.plan.Timeshift = true
		}
		w.recordAdvance()
		w.step = stepGrubBtrfs
		w.setChoices("grub-btrfs integration?", []simpleItem{
			{title: "no", desc: "Skip grub-btrfs."},
			{title: "yes", desc: "Install grub-btrfs (package or source fallback)."},
		})
	case stepGrubBtrfs:
		w.plan.GrubBtrfs = w.choice.SelectedItem().(simpleItem).title == "yes"
		w.recordAdvance()
		w.step = stepConvertHome
		if w.plan.SepHomeDev == "" {
			// No separate /home — skip the convert prompt entirely.
			w.plan.ConvertHome = false
			w.step = stepSafety
			w.setChoices("Safety gates", []simpleItem{
				{title: "plan", desc: "Print the plan only (--dry-run); no disk changes."},
				{title: "execute", desc: "I have backups AND understand this is destructive."},
				{title: "execute (--force-installed)", desc: "Allow running on an installed system."},
			})
		} else {
			w.setChoices("Separate /home partition — convert it to its own Btrfs?", []simpleItem{
				{title: "no", desc: "Leave separate /home as-is; mount it via fstab."},
				{title: "yes", desc: "Reformat it to Btrfs with a single @home subvolume."},
			})
		}
	case stepConvertHome:
		w.plan.ConvertHome = w.choice.SelectedItem().(simpleItem).title == "yes"
		w.recordAdvance()
		w.step = stepSafety
		w.setChoices("Safety gates", []simpleItem{
			{title: "plan", desc: "Print the plan only (--dry-run); no disk changes."},
			{title: "execute", desc: "I have backups AND understand this is destructive."},
			{title: "execute (--force-installed)", desc: "Allow running on an installed system."},
		})
	case stepSafety:
		switch w.choice.SelectedItem().(simpleItem).title {
		case "plan":
			w.plan.DryRun = true
			w.plan.HaveBackups = false
			w.plan.ForceInstalled = false
			w.plan.Yes = false
		case "execute":
			w.plan.DryRun = false
			w.plan.HaveBackups = true
			w.plan.ForceInstalled = false
			w.plan.Yes = true
		case "execute (--force-installed)":
			w.plan.DryRun = false
			w.plan.HaveBackups = true
			w.plan.ForceInstalled = true
			w.plan.Yes = true
		}
		w.recordAdvance()
		w.step = stepReview
		w.setChoices("Ready?", []simpleItem{
			{title: "review", desc: "btrfs-migrate.sh " + strings.Join(w.plan.toArgs(), " ")},
			{title: "run", desc: "Invoke the bash script now (will prompt for sudo)."},
			{title: "quit", desc: "Exit without running anything."},
		})
	case stepReview:
		action := w.choice.SelectedItem().(simpleItem).title
		if action == "run" {
			return w, w.runScript()
		}
		if action == "quit" {
			return w, tea.Quit
		}
	case stepDone:
		return w, tea.Quit
	}
	return w, nil
}

func (w *wizard) runScript() tea.Cmd {
	src, err := locateScript()
	if err != nil {
		w.err = err
		return nil
	}
	args := append([]string{"-E", src.Path}, w.plan.toArgs()...)
	c := exec.Command("sudo", args...)
	return tea.ExecProcess(c, func(err error) tea.Msg {
		src.Cleanup()
		w.err = err
		w.step = stepDone
		return nil
	})
}

func (w *wizard) View() tea.View {
	titleBar := w.st.title.Render(
		fmt.Sprintf("btrfs-migrate %s — interactive wizard", Version))

	idx := w.stepIndex()
	total := len(stepOrder)
	pct := float64(idx) / float64(total)
	progLine := w.progress.ViewAs(pct) + "  " +
		w.st.muted.Render(fmt.Sprintf("step %d of %d", idx, total))

	meta := stepMetaFor[w.step]
	header := w.st.header.Render(meta.title)
	hint := ""
	if meta.hint != "" {
		hint = w.st.muted.Render(meta.hint)
	}

	var body string
	switch w.step {
	case stepIntro:
		body = lipgloss.JoinVertical(lipgloss.Left,
			fmt.Sprintf("This wizard collects a plan and then invokes %s.",
				w.st.keyVal.Render(safeScriptPath())),
			"",
			w.st.warn.Render("⚠  WARNING: This tool performs DESTRUCTIVE disk operations."),
			w.st.muted.Render("   Run with backups. Prefer a Live ISO over an installed system."),
			"",
			w.st.muted.Render("Press Enter to continue, Esc/Ctrl+C to quit."),
		)
	case stepRoot, stepBoot, stepEfi, stepSepHome, stepBiosDisk,
		stepUser, stepSubvols, stepLuksKeyFile:
		body = w.input.View()
	case stepEncrypt, stepEncryptBoot, stepBootloader, stepInstallBoot,
		stepMountOpts, stepSnapshots, stepGrubBtrfs, stepConvertHome,
		stepSafety:
		body = w.choice.View()
	case stepReview:
		args := strings.Join(w.plan.toArgs(), " ")
		if args == "" {
			args = "(no flags — bash script will prompt)"
		}
		body = lipgloss.JoinVertical(lipgloss.Left,
			w.st.panel.Render(lipgloss.JoinVertical(lipgloss.Left,
				w.st.keyKey.Render("Command"),
				w.st.keyVal.Render("btrfs-migrate.sh "+args),
			)),
			"",
			w.choice.View(),
		)
	case stepDone:
		if w.err != nil {
			body = w.st.danger.Render(
				fmt.Sprintf("✘ Script returned: %v", w.err))
		} else {
			body = w.st.success.Render("✓ Done.")
		}
	}

	helpBar := w.st.helpBar.Render(w.help.View(keys))

	layout := lipgloss.JoinVertical(lipgloss.Left,
		titleBar,
		"",
		progLine,
		"",
		header,
		hint,
		"",
		body,
		"",
		helpBar,
	)

	v := tea.NewView(layout)
	v.AltScreen = true
	return v
}

func safeScriptPath() string {
	p, err := findScript()
	if err != nil {
		return "(btrfs-migrate.sh — not yet found; set BTRFS_MIGRATE_SCRIPT)"
	}
	return p
}

// splitArgs walks argv and returns (wrapper, passthrough).
// Wrapper = args before `--non-interactive` or `--`. Passthrough = args
// after. `--non-interactive` is kept in wrapper (so our flag set sees it);
// `--` is discarded (standard Unix convention).
func splitArgs(argv []string) (wrapper, rest []string) {
	for i, a := range argv {
		if a == "--non-interactive" {
			return argv[:i+1], argv[i+1:]
		}
		if a == "--" {
			return argv[:i], argv[i+1:]
		}
	}
	return argv, nil
}

func main() {
	// splitArgs separates wrapper flags from passthrough. Everything up
	// to (and NOT including) `--non-interactive` or `--` goes to our
	// flag set; everything after goes straight to the bash script. This
	// avoids Go's flag package rejecting unknown bash-script flags like
	// --dry-run that it was never meant to parse.
	wrapperArgs, scriptArgs := splitArgs(os.Args[1:])

	fs := flag.NewFlagSet(os.Args[0], flag.ExitOnError)
	var (
		showVer   = fs.Bool("version", false, "print version")
		nonInt    = fs.Bool("non-interactive", false, "skip wizard, pass flags through to the bash script")
		extractTo = fs.String("extract", "", "extract the embedded scripts into the given directory and exit")
		showPath  = fs.Bool("print-script-path", false, "resolve and print the bash script path, then exit")
	)
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, `btrfs-migrate %s (CLI wrapper — Go binary over canonical bash script)

Usage:
  %s                              Launch the interactive Bubble Tea wizard.
  %s --non-interactive [flags]    Pass flags straight through to the bash script (unattended).
  %s --extract DIR                Extract the embedded scripts into DIR and exit.
  %s --print-script-path          Print the resolved bash script path and exit.
  %s --version                    Print version and exit.

Unattended runs require all of the bash script's own flags; in particular
  --yes and --i-have-backups for destructive actions. For the full flag set:
  btrfs-migrate --print-script-path
  $(btrfs-migrate --print-script-path) --help

`, Version, os.Args[0], os.Args[0], os.Args[0], os.Args[0], os.Args[0])
	}
	_ = fs.Parse(wrapperArgs)

	if *showVer {
		fmt.Printf("btrfs-migrate %s (%s/%s)\n", Version, runtime.GOOS, runtime.GOARCH)
		return
	}

	if *extractTo != "" {
		if err := extractScriptsTo(*extractTo); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("extracted scripts to %s\n", *extractTo)
		return
	}

	if *showPath {
		s, err := locateScript()
		if err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(2)
		}
		fmt.Println(s.Path)
		return
	}

	if *nonInt {
		src, err := locateScript()
		if err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(2)
		}
		defer src.Cleanup()
		c := exec.Command("sudo", append([]string{"-E", src.Path}, scriptArgs...)...)
		c.Stdin = os.Stdin
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				os.Exit(ee.ExitCode())
			}
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		return
	}

	p := tea.NewProgram(newWizard(plan{}))
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "wizard error: %v\n", err)
		os.Exit(1)
	}
}
