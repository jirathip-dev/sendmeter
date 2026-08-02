# Issue #416 3D exercise prototype (archived)

This directory preserves the unshipped procedural Three.js prototype created
while exploring issue #416. It included five mannequin-based examples for block
pull, rotator-cuff, and hip-rotation setups, with separate static and movement
presentations.

## Why it is archived

The prototype could be interpreted as prescribing exercise technique while the
app cannot assess joint alignment, appropriate load or range, symptoms, or
whether a movement is suitable for a particular person. The side-lying pose also
did not communicate the intended position reliably. An `Illustrative only`
label did not sufficiently change that overall impression.

The production guide therefore uses equipment-only diagrams and user-authored
reference notes. It explicitly limits Sendmeter to measuring force rather than
selecting an exercise, evaluating form, or providing rehabilitation guidance.

## Contents and revival requirements

- `src/components/ForceExerciseExamples.tsx.txt` — selector and explanatory UI
- `src/components/ForceExerciseScene3D.tsx.txt` — procedural Three.js scene
- `src/lib/forceExerciseExamples.ts.txt` — pose/example definitions
- `src/lib/forceExerciseExamples.test.ts.txt` — prototype invariants
- `styles.css` — styles removed from the production stylesheet

The extra `.txt` suffix keeps reference source out of TypeScript, ESLint, and
Vitest discovery. Remove it only when deliberately reviving the prototype.
These files are intentionally outside the production `src` tree.
Three.js and `@types/three` were removed from production dependencies. Before
revival, the exercise content and every pose, load/range statement, warning, and
claim should be authored or reviewed by a suitably qualified physiotherapist or
sports-medicine professional. The UI must not imply that Sendmeter validates
safe or correct form.

Relevant product boundaries:

- FDA General Wellness Policy for Low Risk Devices
  <https://www.fda.gov/regulatory-information/search-fda-guidance-documents/general-wellness-policy-low-risk-devices>
- FTC Health Products Compliance Guidance
  <https://www.ftc.gov/business-guidance/resources/health-products-compliance-guidance>
- Apple App Review Guidelines, section 1.4 Physical Harm
  <https://developer.apple.com/app-store/review/guidelines/>
