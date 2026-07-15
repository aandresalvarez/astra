# ASTRA Logo Design Brief

## Purpose

This document explains what ASTRA is so a designer can create a logo that feels
accurate to the product, not just attractive in isolation.

ASTRA is a macOS command center for supervising delegated AI work. It helps a
human assign meaningful work to AI agents, watch the work progress, inspect the
evidence, and decide whether the agent should continue, pause, retry, or ask for
help.

The logo should communicate disciplined supervision, durable work, technical
trust, and calm control. It should not look like a generic AI chatbot, a space
startup, a toy automation app, or a decorative academic seal.

## Name

ASTRA is an acronym:

```text
Agent Routines for Tasks, Runs, and Automation
```

Use the product name as uppercase `ASTRA` in primary brand contexts.

The name also has useful associations:

- "Astra" suggests stars, orientation, navigation, and a higher-level view.
- The product helps users supervise work from above rather than getting lost in
  raw transcripts.
- The logo can lightly reference navigation, constellations, direction, or a
  guiding star, but it should not become a literal space or astronomy logo.

## One-Sentence Product Definition

ASTRA is a local macOS supervision layer for AI agents: it turns ad hoc AI chat
sessions into durable workspaces where people can assign tasks, preserve
context, review outputs, and keep humans in control.

## Core Product Idea

The product model is:

```text
agent -> delegated work -> supervision
```

ASTRA is not primarily a chat app, task list, workflow builder, or generic
dashboard. It is a supervision system for delegated work.

The most important promise is:

```text
Supervise meaningful work, not raw transcripts.
```

That sentence should drive the logo. The mark should feel like a clear command
surface for serious work, not like a stream of messages.

## What ASTRA Does

ASTRA lets users:

- Create durable workspaces that behave like long-lived software agents.
- Give each workspace instructions, memory, tools, access, schedules, and task
  history.
- Queue, run, resume, fork, and review AI-powered tasks.
- See whether a task is drafted, queued, running, waiting on the user,
  completed, failed, cancelled, or over budget.
- Review artifacts such as diffs, documents, logs, notes, reports, and changed
  files.
- Connect capabilities such as GitHub, Jira, Google Cloud, REDCap, browser
  control, mail, local tools, skills, and provider CLIs.
- Validate local prerequisites before agents start work.
- Keep work local, inspectable, and auditable on macOS.
- Separate development and production app identities so real work is protected
  during development.

The logo should imply that ASTRA is an operating layer around AI work: structured,
visible, and accountable.

## Target Users

ASTRA is for people who need the leverage of AI agents but cannot give up
control:

- Technical leaders supervising multiple engineering tasks.
- Software engineers delegating repeatable implementation, debugging, and
  review work.
- Research, data, and operations teams that need local auditability.
- Users working with sensitive workspaces, credentials, institutional tools, and
  local files.
- People who want AI agents to act like durable operators, not disposable chat
  sessions.

The logo should feel credible to a senior engineer or technical operator. It can
be elegant, but it should not feel cute, mystical, or consumer-social.

## Personality

ASTRA should feel:

- Calm.
- Capable.
- Precise.
- Trustworthy.
- Local and grounded.
- Technical without being cold.
- Academic without being ornate.
- Supervisory without being authoritarian.
- Powerful without looking flashy.

ASTRA should not feel:

- Hype-driven.
- Neon or futuristic for its own sake.
- Overly robotic.
- Like a generic sparkle AI assistant.
- Like a chat bubble.
- Like a space exploration brand.
- Like a security-only product.
- Like a project management clone.

## Brand Context

The current product language is Stanford-inspired. The app uses a restrained
palette, warm reading surfaces, serif headings, sans-serif UI text, and compact
macOS-native controls.

Important existing color tokens:

| Role | Hex | Notes |
| --- | --- | --- |
| Cardinal red | `#8C1515` | Primary Stanford-inspired brand color in light mode |
| Dark-mode cardinal | `#D93A3A` | Brighter red for dark surfaces |
| Warm canvas | `#F8F6F2` | Off-white app reading surface |
| Reading text | `#2E2D29` | Warm charcoal |
| Dark reading text | `#E7E1D8` | Warm off-white for dark mode |
| Palo Alto green | `#175E54` | Trust, completion, healthy status |
| Bay | `#6FA287` | Muted green secondary accent |
| Lagunita | `#007C92` | Running, focus, links, interaction |
| Sky | `#0098DB` | Informational and interactive accent |
| Poppy | `#E98300` | Warnings and user attention |
| Illuminating | `#FEC51D` | Highlight accent |
| Plum | `#620059` | Tools and capability accent |
| Sandstone | `#B6B1A9` | Neutral queued state |
| Driftwood | `#B3995D` | Warm neutral accent |

The logo does not need to use every color. In fact, it should use very few. A
strong candidate will likely use cardinal red plus warm off-white, with one
secondary accent only if it improves meaning.

## Existing Logo and Icon Direction

The current app icon is a macOS rounded square with a deep cardinal red
background and a large cream `A` monogram. The `A` has a strong academic feel
and references Stanford-like typography.

Existing icon iteration files live here:

```text
docs/icon-iterations/
```

Notable files:

- `astra-icon-v1-master.png`
- `astra-icon-v2-stanford-master.png`
- `astra-icon-v3-a-monogram-master.png`
- `astra-icon-v4-a-monogram-master.png`
- `astra-icon-v5-arch-a-master.png`
- `astra-icon-v6-custom-a-triangle.png`
- `astra-icon-v7-custom-a-arch.png`
- `astra-icon-v8-stroked-a.png`

The active app icon masters are:

```text
docs/icon-iterations/astra-icon-v9-reticle-master.png
docs/icon-iterations/astra-icon-v9-reticle-dev-master.png
```

The masters reserve a 64 px transparent margin around an 896 px optical tile.
That 87.5% canvas fill keeps ASTRA visually aligned with neighboring macOS Dock
icons. The packaged icon resources are `Astra/Resources/AppIcon.icns` and
`Astra/Resources/AppIconDev.icns`.

The next logo should preserve what works:

- Strong single-letter recognition.
- High contrast.
- Serious academic tone.
- Good macOS app icon silhouette.
- Simplicity at small sizes.

But the next logo can improve what is missing:

- More connection to AI delegation and supervision.
- Less dependence on a plain academic `A`.
- A clearer sense of orchestration, review, or command.
- A mark that can work outside the macOS icon tile.

## Visual Metaphors That Fit

These metaphors are appropriate if handled subtly:

- Command center: a central point coordinating work.
- Observatory: seeing the whole system from a higher vantage point.
- Navigation star: orientation and guidance.
- Constellation: multiple agents, tasks, tools, and workspaces connected by a
  coherent system.
- Checkpoint: human review before action continues.
- Work queue: ordered, supervised execution.
- Lens or aperture: focused inspection of evidence.
- Shielded workspace: local, bounded, auditable work.
- Architectural arch: academic trust, structure, and institutional memory.
- Monogram `A`: direct product recognition.

The best direction may combine a monogram `A` with one secondary idea:

- `A` as an arch or doorway into a workspace.
- `A` as a command tower or observation point.
- `A` with a small guiding star, node, or path.
- `A` built from connected task paths.
- `A` enclosing a calm review aperture or triangular focus area.
- `A` whose crossbar suggests a checkpoint or human approval gate.

## Visual Metaphors To Avoid

Avoid:

- Generic sparkles as the main symbol.
- Chat bubbles.
- Robot heads.
- Brain icons.
- Circuit-board cliches.
- Rocket ships.
- Literal telescopes.
- Planets, galaxies, or sci-fi scenes.
- Overly complex node graphs.
- Official Stanford marks such as the block `S`, tree seal, or university seal
  unless the project has explicit rights to use them.
- Lock-only imagery that makes ASTRA look like a security product.
- Kanban-only imagery that makes ASTRA look like a task board.

## Functional Product Concepts To Encode

If the designer wants the mark to carry product meaning, prioritize these
concepts:

1. Durable agent identity.
2. Human supervision.
3. Controlled execution.
4. Review before trust.
5. Workspaces with memory and tools.
6. Local, inspectable, auditable work.
7. Calm operational clarity.

Lower priority concepts:

- "AI" in the generic sparkle sense.
- "Automation" as speed alone.
- "Chat" or conversation.
- "Project management."
- "Space" despite the name.

## Product Surfaces The Logo Must Fit

The logo should work in:

- macOS app icon at `16`, `32`, `64`, `128`, `256`, `512`, and `1024` px.
- Finder, Dock, Launchpad, app switcher, and notifications.
- A sidebar app identity area.
- About window.
- GitHub README.
- Release notes and update prompts.
- Light and dark mode.
- Monochrome or single-color contexts.
- Small favicons or social preview crops if the project later gets a website.

Small-size recognition matters. At `16` px, the logo should reduce to a clear
silhouette, not a detailed diagram.

## App Icon Requirements

For the macOS app icon:

- Use a rounded-square macOS icon tile.
- Keep the central mark large and optically centered.
- Maintain enough internal padding that the mark does not feel cramped in the
  Dock.
- Avoid thin strokes that disappear below `64` px.
- Avoid intricate cutouts that become noisy at small sizes.
- Make the silhouette recognizable in both light and dark macOS appearances.
- Ensure the icon does not rely on a drop shadow for legibility.
- Export a full icon set suitable for the existing asset catalog.

## Logo System Requirements

The designer should deliver more than one square app icon. ASTRA needs a small
identity system:

- Primary app icon.
- Standalone symbol without the macOS rounded-square tile.
- Horizontal lockup with `ASTRA`.
- Monochrome version.
- Reversed version for dark backgrounds.
- Small-size version simplified for `16` and `32` px.
- Optional development-channel variant for `ASTRA Dev.app`.

The development variant should be visibly related to production but not easily
confused with it. A small secondary accent, outline, corner mark, or `Dev`
treatment is preferable to a completely separate logo.

## Typography Direction

The app currently uses:

- Source Serif 4 for headings and more editorial moments.
- Source Sans 3 for UI and body text.
- Roboto Mono for code and technical content.

The wordmark does not have to use those exact fonts, but it should harmonize
with them. Good directions:

- A refined serif wordmark that supports the academic tone.
- A precise sans-serif wordmark if the symbol already carries the academic cue.
- Custom lettering for the `A` if the monogram is the core mark.

Avoid:

- Rounded startup sans-serif logos that feel generic.
- Futuristic sci-fi typography.
- Overly decorative university-style lettering.
- Thin hairline type that fails in app UI.

## Color Direction

Recommended primary direction:

- Cardinal red background: `#8C1515`.
- Warm off-white mark: close to `#F8F6F2` or `#E7E1D8`.
- Warm charcoal text: `#2E2D29`.

Optional secondary accents:

- Lagunita teal `#007C92` for active/running/supervision cues.
- Palo Alto green `#175E54` for trust/completion cues.
- Poppy `#E98300` only for attention or review states, not as a dominant logo
  color.

Avoid a logo dominated by blue-purple gradients. That would make ASTRA look too
much like a generic AI SaaS tool and too little like a grounded macOS command
center.

## Shape Language

Prefer:

- Strong geometric structure.
- Clear central axis.
- Stable proportions.
- Slight warmth through corners, serif influence, or optical corrections.
- One memorable negative-space idea.
- A mark that feels assembled and intentional, not generated.

Avoid:

- Excessively rounded playful shapes.
- Overly sharp aggressive shapes.
- Dense mesh networks.
- Tiny stars or nodes that disappear.
- Multiple nested cards or panels as a logo metaphor.

## Possible Design Directions

### Direction 1: Supervision Monogram

A custom `A` monogram where the crossbar reads as a review gate or command
checkpoint. The inner counter could become a focused aperture, implying that
ASTRA turns agent work into inspectable evidence.

Why it fits:

- Preserves the current app icon's recognition.
- Connects the letterform to supervision.
- Works at small sizes.

Risks:

- Could still feel like a generic academic initial if the review-gate idea is
  too subtle.

### Direction 2: Navigation A

An `A` constructed with a small guiding point or path, like a simplified
navigation star moving through a structured route. The route should be minimal:
one or two nodes, not a full network.

Why it fits:

- Connects to the name ASTRA without becoming space-themed.
- Suggests direction, delegation, and progress.

Risks:

- Too many stars or paths will make it look like a constellation app.

### Direction 3: Observatory Arch

An `A` that also reads as an arch or observatory aperture: an institutional form
that frames work below it. This can reference academic credibility and a
higher-level view.

Why it fits:

- Aligns with the Stanford-inspired visual language.
- Communicates structure, oversight, and permanence.

Risks:

- Too architectural can feel like a university department logo rather than a
  software product.

### Direction 4: Agent Control Mark

A symbol that shows a central human-supervision point coordinating a few bounded
agent paths. This could be abstract rather than letter-based, then paired with a
wordmark.

Why it fits:

- Strongly represents the product model.
- Can distinguish ASTRA from a plain monogram.

Risks:

- Harder to recognize at small macOS icon sizes.
- May become a generic node graph if not simplified.

## Recommended Direction

Start with a custom `A` monogram and embed one product-specific idea: supervision
as a checkpoint, lens, or guiding node.

The reason is practical. ASTRA already has a strong `A` icon lineage, the app
name begins with `A`, and macOS app icons benefit from a simple central mark.
The opportunity is to make the `A` less like a plain academic initial and more
like a symbol for controlled delegated work.

The mark should answer:

- Can I recognize this instantly as ASTRA?
- Does it feel like a serious macOS tool?
- Does it imply AI work is being supervised, not just generated?
- Does it still work at `16` px?

## Accuracy Checklist

Before finalizing, check the proposed logo against these statements:

- It represents a supervision layer, not a chat app.
- It feels local, auditable, and trustworthy.
- It supports serious technical work.
- It can coexist with Stanford-inspired colors and typography.
- It is simple enough for a macOS app icon.
- It does not rely on generic AI sparkles.
- It does not over-index on space imagery.
- It has a clear relationship to the name `ASTRA`.
- It can support both production and development app variants.
- It feels calm and controlled rather than loud or magical.

## Deliverables Requested From Designer

Ask the designer for:

- Three distinct logo concepts.
- Each concept shown as a macOS app icon.
- Each concept shown as a standalone mark.
- Each concept shown in a horizontal `ASTRA` lockup.
- Light and dark background examples.
- `16`, `32`, `64`, `128`, `256`, `512`, and `1024` px app icon previews.
- Monochrome test.
- Production and development-channel variant proposal.
- Short rationale explaining how the concept represents supervised delegated AI
  work.
- Final vector source files.
- Final exported PNG app icon set.

## Short Creative Prompt

Design a logo for ASTRA, a Stanford-inspired macOS command center for supervising
delegated AI work. ASTRA stands for Agent Routines for Tasks, Runs, and
Automation. It turns ad hoc AI chat into durable workspaces where humans assign
tasks to agents, review evidence, inspect artifacts, and decide when work should
continue, pause, or ask for help. The logo should feel calm, precise, academic,
technical, and trustworthy. Prefer a strong custom `A` monogram or simple mark
that suggests supervision, navigation, and controlled execution. Use cardinal
red and warm off-white as the primary palette. Avoid generic AI sparkles, chat
bubbles, robot heads, sci-fi space imagery, and official Stanford marks.
