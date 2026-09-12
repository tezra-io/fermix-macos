import CoreGraphics
import Foundation

/// The seven-step spacing scale (`M34_DESIGN_SYSTEM_REDLINES.md` §3). Nothing
/// is off-scale except the documented odd paddings, which are load-bearing
/// artboard values and live on the component that uses them.
public enum Spacing {
    public static let xxs: Double = 4
    public static let xs: Double = 8
    public static let s: Double = 12
    public static let m: Double = 16
    public static let l: Double = 24
    public static let xl: Double = 32
    public static let xxl: Double = 48

    public static let scale: [Double] = [xxs, xs, s, m, l, xl, xxl]
}

/// Corner radii. Pills, orbs, and dots are capsules and have no entry.
public enum Radius {
    public static let controlCompact: Double = 8
    public static let control: Double = 10
    public static let card: Double = 12
    public static let window: Double = 14
    public static let iconTile: Double = 8
    public static let iconTileSmall: Double = 6
}

/// What happens inside one grouped-form row (redlines §5.8; owner directive of
/// 2026-09-03: "some of the items are stuck together without proper spacing").
///
/// A row is ONE grouped-form row however many lines it draws, so the form's own
/// row insets stop at that row's edge and never reach the lines inside it.
/// Everything a row stacks is spaced from here rather than at each call site,
/// so a pane that grows a second stacked editor takes the rhythm instead of
/// deciding it again. Home's Runtime section is a grouped form too, which is
/// why its vendor mark is measured here rather than beside Home.
public enum SettingsRowMetrics {
    /// A control and the caption under it. One thought, so it takes the
    /// tightest gap on the scale. This is not the reported defect: the Memory
    /// and Coding agents panes draw exactly this pair and read correctly.
    public static let captionGap: Double = Spacing.xxs
    /// Peer lines a row stacks: a list editor's label, its entries, and the
    /// field that adds one. They are separate things rather than a control and
    /// its footnote, so they take the wider gap.
    public static let stackGap: Double = Spacing.s
    /// One entry inside a stacked editor. It keeps two `Remove` buttons off
    /// each other: at the caption gap two 24-point buttons sat a point apart,
    /// which is what the Sandbox pane's allowed-variable list was showing.
    public static let entryGap: Double = Spacing.xs
    /// The editable figure in a number row. Wide enough for a four-digit count
    /// and narrow enough that the unit beside it still reads as a suffix.
    public static let numberFieldWidth: Double = 64
    /// The leading accessory column of a grouped-form row: the vendor mark
    /// where the row is about one vendor, and the system symbol where it leads
    /// with one instead. One number for both, so the rows of one form line up
    /// whichever kind of accessory they carry. Smaller than the plugin page's
    /// 28-point tile: a grouped-form row is a line of text, and an accessory
    /// taller than its cap height sets the row's height instead of sitting
    /// inside it.
    public static let markSize: Double = 20
}

/// Minimum interactive heights.
public enum HitTarget {
    public static let button: Double = 36
    public static let onboardingCTA: Double = 44
}

/// Stroke widths. Only the Telegram hero card is heavier than a hairline.
public enum Stroke {
    public static let hairline: Double = 1
    public static let heroBorder: Double = 1.5
    /// The one icon family: stroked, 1.8pt, on a 16/20/24 grid.
    public static let icon: Double = 1.8
}

/// Window and panel geometry (`M34_DESIGN_SYSTEM_REDLINES.md` §5.7, M34 §3.1).
public enum WindowMetrics {
    /// Fixed, non-resizable, centred on the backdrop.
    public static let onboardingSize = CGSize(width: 800, height: 520)
    /// Default size; the main window is resizable.
    ///
    /// Decision D3 (owner directive of 2026-09-03): the settings presentation
    /// runs inside this window, so the default is the size that shows a 240 pt
    /// pane column beside a readable content column.
    public static let mainDefaultSize = CGSize(width: 1040, height: 640)

    /// The sidebar column the system lays out. Three numbers rather than one:
    /// `NavigationSplitView` owns the width and the user can drag inside this
    /// range, which is what makes the column resizable at all.
    public static let sidebarMinWidth: Double = 180
    public static let sidebarIdealWidth: Double = 200
    public static let sidebarMaxWidth: Double = 260

    /// The window floor. One number rather than the pair a separate Settings
    /// window allowed, because decision D3 puts settings inside this window:
    /// the 240 pt pane column plus a readable content column has to fit at
    /// every size the user can reach, collapsed sidebar or not.
    public static let mainMinimumSize = CGSize(width: 760, height: 520)

    /// The fixed settings pane column. One number, not three: this column does
    /// not resize and does not collapse.
    public static let settingsSidebarWidth: Double = 240
    /// The detail column's content ceiling, so a widened window grows its
    /// margins rather than its line length.
    public static let settingsContentMaxWidth: Double = 640
    /// The inset a grouped `Form` puts between its own edge and its section
    /// cards, measured off the shipped panes. It is here so the banner that
    /// floats above the form can land on the same leading and trailing edge as
    /// the cards under it: a bar on the full window width reads as a different
    /// column from everything it sits over.
    public static let settingsFormCardInset: Double = 30
    /// The leading inset a grouped `Form` gives its section headers and its row
    /// labels on macOS, measured off the shipped surfaces the same way the card
    /// inset above was. It is here so a header drawn *outside* a form can land
    /// its first word on the same edge as the words inside it: Home's status
    /// line sat three points right of `Background` under it, which reads as a
    /// misprint rather than as a heading.
    public static let groupedFormLabelInset: Double = 45
    /// The status dot beside Home's state word. Decoration: the word carries
    /// the state, so the dot hangs into the margin and the word keeps the
    /// form's own edge.
    public static let statusDotDiameter: Double = 12

    public static let progressDotZoneHeight: Double = 44
    /// The ladder's ceiling, not its width: it takes the width the surface
    /// offers and stops here. Fixed at 380 the longest row it draws —
    /// `Restarting Fermix so your provider takes effect` — wrapped to two
    /// lines inside the 800-point assistant window, which is the one window
    /// the ladder is ever drawn in. The number is the assistant's own content
    /// width, so the ladder measures against the same column every other
    /// screen does.
    public static let ladderMaxWidth: Double = OnboardingMetrics.contentWidth
    /// The one leading edge: every surface uses this horizontal and bottom
    /// padding, so the surfaces that are not grouped forms align to a single
    /// content grid.
    public static let contentPadding: Double = 24
}

/// The onboarding card's own grid.
public enum OnboardingMetrics {
    /// One content width across every step: the fixed 800-point card pads
    /// Welcome, Activate, Ready, and Recovery identically, so the surfaces
    /// never jump sideways between steps.
    public static let horizontalPadding: Double = 100
    /// The mascot on Starting and Ready. It stands where §5.2's 96-point orb
    /// stood and where §5.5 already asked for a mascot, so one number serves
    /// both and the two screens cannot drift apart.
    public static let mascotSize: Double = 96
    /// The assistant's one content column: the line of subcopy a screen is
    /// allowed, the provider rows, the About you form, and every sentence a
    /// screen states. One number, so the eight screens read as one layout
    /// rather than eight (owner directive of 2026-09-03: the screens read
    /// text-heavy and unbalanced).
    public static let contentWidth: Double = 460
    /// Ready's next-step column, which redline §5.5 publishes at 470 because
    /// the `fermix` command row inside it is wider than a sentence.
    public static let nextStepsWidth: Double = 470
    /// The vendor mark leading an assistant form row. Smaller than the 36-point
    /// disc the artboard drew on a 64-point card, because a grouped-form row is
    /// a line of text and a mark taller than the row sets the row's height
    /// instead of sitting inside it.
    public static let rowMarkSize: Double = 28
}

/// The progress-dot zone at the foot of every onboarding screen.
public enum ProgressDotMetrics {
    public static let activeSize = CGSize(width: 22, height: 6)
    public static let inactiveDiameter: Double = 6
    public static let gap: Double = 8
}

/// The menu-bar status item (`M34_DESIGN_SYSTEM_REDLINES.md` §5.10).
///
/// These are the template rasters' geometry, not a view's: the status item
/// draws an `NSImage` the system sizes, so the drawing lives in
/// `scripts/build_menu_bar_template.py` and these are what the app asserts the
/// shipped rasters against.
public enum MenuBarGlyphMetrics {
    /// The image box. 18 points is the canonical menu bar template size and the
    /// largest that clears the bar's own vertical padding, so nothing is cut.
    public static let imageSize: Double = 18
    /// Clear space around the mark inside that box.
    public static let markInset: Double = 1
    /// The attention badge, cut into the same alpha as the mark so it tints
    /// with it and is a shape rather than a colour cue.
    ///
    /// The redline's 7 by 1.5 was a badge that OVERHUNG a 16-point glyph, which
    /// is exactly what the status button clipped. Cut into the box it has to be
    /// smaller, or it swallows the mark's trailing lobe.
    ///
    /// It also means the attention state is not the running outline plus a dot:
    /// the ring clears the mark's top-trailing pixels, so that corner of the
    /// silhouette is replaced rather than overlaid. That is the trade the
    /// 18-point ceiling forces, and it is recorded here because it is the one
    /// visible difference between the two states beyond the badge itself.
    public static let badgeDiameter: Double = 5
    /// The transparent ring that holds the badge off the mark.
    public static let badgeRingWidth: Double = 1
}
