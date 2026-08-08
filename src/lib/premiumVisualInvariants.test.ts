import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import * as ts from "typescript";
import { describe, expect, it } from "vitest";

const SRC = join(import.meta.dirname, "..");
const css = readFileSync(join(SRC, "index.css"), "utf8");
const indexHtml = readFileSync(join(SRC, "..", "index.html"), "utf8");
const design = readFileSync(join(SRC, "..", "DESIGN.md"), "utf8");
const mainSource = readFileSync(join(SRC, "..", "src", "main.tsx"), "utf8");
const zoneSelectionSource = readFileSync(join(SRC, "lib", "zoneSelection.ts"), "utf8");
const manifestPath = join(SRC, "..", "public", "manifest.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as {
  background_color?: string;
  theme_color?: string;
};
const viteConfig = readFileSync(join(SRC, "..", "vite.config.ts"), "utf8");
const themeSource = readFileSync(join(SRC, "lib", "theme.ts"), "utf8");
const bootstrapSource = indexHtml.match(
  /<script\b[^>]*data-theme-bootstrap[^>]*>([\s\S]*?)<\/script>/i,
)?.[1] ?? "";
const packageScripts = (
  JSON.parse(readFileSync(join(SRC, "..", "package.json"), "utf8")) as {
    scripts?: Record<string, string>;
  }
).scripts ?? {};

function component(name: string): string {
  return readFileSync(join(SRC, "components", name), "utf8");
}

function componentSources(): Array<[string, string]> {
  const componentsRoot = join(SRC, "components");
  const files: string[] = [];
  const visit = (directory: string): void => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.isFile() && entry.name.endsWith(".tsx")) files.push(path);
    }
  };
  visit(componentsRoot);
  files.sort();
  return [
    ["src/App.tsx", readFileSync(join(SRC, "App.tsx"), "utf8")],
    ...files.map((path) => [
      `src/components/${path.slice(componentsRoot.length + 1)}`,
      readFileSync(path, "utf8"),
    ] as [string, string]),
  ];
}

interface ButtonRegion {
  tag: string;
  element: string;
}

interface ButtonConsumer extends ButtonRegion {
  file: string;
  classValue: string;
  styleValue: string | null;
  astViolations?: string[];
}

/**
 * Fixture-only balanced extractor used by the recovery-order and legacy
 * negative fixtures below. The production consumer audit uses TypeScript's
 * JSX AST (`auditButtonSource`) so it cannot be fooled by nested braces.
 */
function buttonRegions(source: string): ButtonRegion[] {
  const regions: ButtonRegion[] = [];
  let cursor = 0;
  while (true) {
    const start = source.indexOf("<button", cursor);
    if (start < 0) return regions;

    let braceDepth = 0;
    let quote: "'" | '"' | "`" | null = null;
    let end = start + "<button".length;
    for (; end < source.length; end += 1) {
      const character = source[end]!;
      if (quote) {
        if (character === quote && source[end - 1] !== "\\") quote = null;
        continue;
      }
      if (character === "'" || character === '"' || character === "`") {
        quote = character;
      } else if (character === "{") {
        braceDepth += 1;
      } else if (character === "}") {
        braceDepth = Math.max(0, braceDepth - 1);
      } else if (character === ">" && braceDepth === 0) {
        break;
      }
    }
    const tag = source.slice(start, end + 1);
    const closingStart = source.indexOf("</button>", end + 1);
    const closingEnd = closingStart < 0 ? end + 1 : closingStart + "</button>".length;
    regions.push({ tag, element: source.slice(start, closingEnd) });
    cursor = end + 1;
  }
}

/** Return JSX spread attributes at the opening-tag level, excluding spreads
 * nested inside a style object (which are inspected separately below). */
function spreadAttributes(tag: string): string[] {
  const spreads: string[] = [];
  let quote: "'" | '"' | "`" | null = null;
  let braceDepth = 0;
  for (let cursor = 0; cursor < tag.length; cursor += 1) {
    const character = tag[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(tag, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      continue;
    }
    if (character === "{") {
      if (braceDepth === 0 && /^\{\s*\.\.\./.test(tag.slice(cursor))) {
        const end = matchingJsBrace(tag, cursor);
        spreads.push(tag.slice(cursor, end < 0 ? tag.length : end + 1));
        cursor = end < 0 ? tag.length : end;
        continue;
      }
      braceDepth += 1;
    } else if (character === "}") {
      braceDepth = Math.max(0, braceDepth - 1);
    }
  }
  return spreads;
}

function attributeValue(tag: string, name: string): string | null {
  const marker = new RegExp(`\\b${name}\\s*=`).exec(tag);
  if (!marker) return null;
  let cursor = marker.index + marker[0].length;
  while (/\s/.test(tag[cursor] ?? "")) cursor += 1;
  const first = tag[cursor];
  if (first === '"' || first === "'") {
    const quote = first;
    let end = cursor + 1;
    while (end < tag.length) {
      if (tag[end] === quote && tag[end - 1] !== "\\") return tag.slice(cursor, end + 1);
      end += 1;
    }
    return tag.slice(cursor);
  }
  if (first !== "{") return tag.slice(cursor).split(/\s|>/, 1)[0] ?? "";

  let braceDepth = 0;
  let quote: "'" | '"' | "`" | null = null;
  for (let end = cursor; end < tag.length; end += 1) {
    const character = tag[end]!;
    if (quote) {
      if (character === quote && tag[end - 1] !== "\\") quote = null;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
    } else if (character === "{") {
      braceDepth += 1;
    } else if (character === "}") {
      braceDepth -= 1;
      if (braceDepth === 0) return tag.slice(cursor, end + 1);
    }
  }
  return tag.slice(cursor);
}

const INLINE_PAINT_PROPERTIES = new Set([
  "background",
  "backgroundColor",
  "backgroundImage",
  "border",
  "borderColor",
  "borderImage",
  "borderInline",
  "borderInlineColor",
  "borderBlock",
  "borderBlockColor",
  "color",
  "opacity",
  "boxShadow",
  "all",
  "WebkitTextFillColor",
  "WebkitTapHighlightColor",
  "outline",
  "outlineColor",
  "textShadow",
  "textDecorationColor",
  "fill",
  "stroke",
  "caretColor",
  "accentColor",
  "colorScheme",
]);

function matchingJsBrace(source: string, open: number): number {
  let depth = 1;
  let quote: "'" | '"' | "`" | null = null;
  for (let cursor = open + 1; cursor < source.length; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      if (depth === 0) return cursor;
    }
  }
  return -1;
}

function splitTopLevel(source: string, delimiter: string): string[] {
  const parts: string[] = [];
  let start = 0;
  let braceDepth = 0;
  let bracketDepth = 0;
  let parenDepth = 0;
  let quote: "'" | '"' | "`" | null = null;
  for (let cursor = 0; cursor < source.length; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
    } else if (character === "{") {
      braceDepth += 1;
    } else if (character === "}") {
      braceDepth = Math.max(0, braceDepth - 1);
    } else if (character === "[") {
      bracketDepth += 1;
    } else if (character === "]") {
      bracketDepth = Math.max(0, bracketDepth - 1);
    } else if (character === "(") {
      parenDepth += 1;
    } else if (character === ")") {
      parenDepth = Math.max(0, parenDepth - 1);
    } else if (
      source.startsWith(delimiter, cursor) &&
      braceDepth === 0 &&
      bracketDepth === 0 &&
      parenDepth === 0
    ) {
      parts.push(source.slice(start, cursor));
      start = cursor + delimiter.length;
      cursor += delimiter.length - 1;
    }
  }
  parts.push(source.slice(start));
  return parts;
}

function topLevelIndex(source: string, needle: string): number {
  let braceDepth = 0;
  let bracketDepth = 0;
  let parenDepth = 0;
  let quote: "'" | '"' | "`" | null = null;
  for (let cursor = 0; cursor < source.length; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
    } else if (character === "{") {
      braceDepth += 1;
    } else if (character === "}") {
      braceDepth = Math.max(0, braceDepth - 1);
    } else if (character === "[") {
      bracketDepth += 1;
    } else if (character === "]") {
      bracketDepth = Math.max(0, bracketDepth - 1);
    } else if (character === "(") {
      parenDepth += 1;
    } else if (character === ")") {
      parenDepth = Math.max(0, parenDepth - 1);
    } else if (
      source.startsWith(needle, cursor) &&
      braceDepth === 0 &&
      bracketDepth === 0 &&
      parenDepth === 0
    ) {
      return cursor;
    }
  }
  return -1;
}

function unsafeStyleObject(body: string): boolean {
  for (const property of splitTopLevel(body, ",")) {
    const trimmed = property.trim();
    if (!trimmed) continue;
    if (trimmed.startsWith("...")) return true;
    const colon = topLevelIndex(trimmed, ":");
    const key = (colon < 0 ? trimmed : trimmed.slice(0, colon)).trim();
    if (key.startsWith("[") || key.startsWith("{")) return true;
    const normalizedKey = key.replace(/^(?:["'])(.*)(?:["'])$/, "$1");
    if (normalizedKey.startsWith("--")) return true;
    if (INLINE_PAINT_PROPERTIES.has(normalizedKey)) return true;
    // A shorthand property is an opaque value and may be a paint property.
    // Explicit assignments are inspectable and safe unless they name paint.
    if (colon < 0 && !normalizedKey.startsWith("--")) return true;
  }
  return false;
}

function unsafeStyleExpression(styleValue: string | null): boolean {
  if (!styleValue) return false;
  const source = styleValue.trim();
  if (!source.startsWith("{") || matchingJsBrace(source, 0) < 0) return true;
  const expressionEnd = matchingJsBrace(source, 0);
  if (expressionEnd !== source.length - 1) {
    // Object style casts (`{{ ... } as CSSProperties}`) are safe to inspect;
    // arbitrary suffixes and type assertions on unknown values are not.
    const suffix = source.slice(expressionEnd + 1).trim();
    if (!/^as\s+[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*$/.test(suffix)) return true;
  }
  const expression = source.slice(1, expressionEnd).trim();
  const question = topLevelIndex(expression, "?");
  if (question >= 0) {
    const branches = splitTopLevel(expression.slice(question + 1), ":");
    if (branches.length !== 2) return true;
    return branches.some((branch) => unsafeStyleExpression(`{${branch.trim()}}`));
  }
  if (expression === "undefined" || expression === "null") return false;
  if (!expression.startsWith("{")) return true;
  const objectEnd = matchingJsBrace(expression, 0);
  if (objectEnd < 0) return true;
  const objectSuffix = expression.slice(objectEnd + 1).trim();
  if (
    objectSuffix &&
    !/^as\s+[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*$/.test(objectSuffix)
  ) {
    return true;
  }
  return unsafeStyleObject(expression.slice(1, objectEnd));
}

interface AstClassAnalysis {
  tokens: Set<string>;
  guaranteedRecipe: boolean;
  opaque: boolean;
}

type LocalClassResolver = (name: string) => ts.Expression | undefined;

const READABLE_INK_VALUES = new Set([
  "var(--ink)",
  "var(--ink-muted)",
  "var(--ink-faint)",
  "currentColor",
]);

function cssButtonRecipeClasses(): Set<string> {
  const classes = new Set<string>();
  for (const rule of parsedCssRules) {
    for (const match of rule.selector.matchAll(/\.([A-Za-z_][\w-]*)/g)) {
      if (match[1]) classes.add(match[1]);
    }
  }
  return classes;
}

function unwrapTsExpression(expression: ts.Expression): ts.Expression {
  let current = expression;
  while (
    ts.isParenthesizedExpression(current) ||
    ts.isAsExpression(current) ||
    ts.isTypeAssertionExpression(current) ||
    (ts.isSatisfiesExpression?.(current) ?? false)
  ) {
    if (ts.isParenthesizedExpression(current)) current = current.expression;
    else if (ts.isAsExpression(current)) current = current.expression;
    else if (ts.isTypeAssertionExpression(current)) current = current.expression;
    else current = (current as ts.SatisfiesExpression).expression;
  }
  return current;
}

function classTokens(text: string): Set<string> {
  return new Set(text.split(/\s+/).map((token) => token.trim()).filter(Boolean));
}

function mergeClassAnalyses(analyses: AstClassAnalysis[]): AstClassAnalysis {
  return {
    tokens: new Set(analyses.flatMap((analysis) => [...analysis.tokens])),
    guaranteedRecipe: analyses.some((analysis) => analysis.guaranteedRecipe),
    opaque: analyses.some((analysis) => analysis.opaque),
  };
}

function analyzeClassExpression(
  expression: ts.Expression | undefined,
  recipeClasses: Set<string>,
  resolveLocal?: LocalClassResolver,
  resolving = new Set<string>(),
): AstClassAnalysis {
  if (!expression) return { tokens: new Set(), guaranteedRecipe: false, opaque: true };
  const current = unwrapTsExpression(expression);
  if (ts.isStringLiteral(current) || ts.isNoSubstitutionTemplateLiteral(current)) {
    const tokens = classTokens(current.text);
    return {
      tokens,
      guaranteedRecipe: [...tokens].some((token) => recipeClasses.has(token)),
      opaque: false,
    };
  }
  if (ts.isTemplateExpression(current)) {
    const staticText = [current.head.text, ...current.templateSpans.map((span) => span.literal.text)].join(" ");
    const tokens = classTokens(staticText);
    const dynamic = current.templateSpans.map((span) =>
      analyzeClassExpression(span.expression, recipeClasses, resolveLocal, resolving),
    );
    return {
      tokens: new Set([...tokens, ...dynamic.flatMap((analysis) => [...analysis.tokens])]),
      guaranteedRecipe:
        [...tokens].some((token) => recipeClasses.has(token)) ||
        (dynamic.length > 0 && dynamic.every((analysis) => analysis.guaranteedRecipe)),
      opaque: true,
    };
  }
  if (ts.isConditionalExpression(current)) {
    const branches = [
      analyzeClassExpression(current.whenTrue, recipeClasses, resolveLocal, resolving),
      analyzeClassExpression(current.whenFalse, recipeClasses, resolveLocal, resolving),
    ];
    const merged = mergeClassAnalyses(branches);
    return { ...merged, guaranteedRecipe: branches.every((branch) => branch.guaranteedRecipe) };
  }
  if (ts.isBinaryExpression(current)) {
    const left = analyzeClassExpression(current.left, recipeClasses, resolveLocal, resolving);
    const right = analyzeClassExpression(current.right, recipeClasses, resolveLocal, resolving);
    const merged = mergeClassAnalyses([left, right]);
    if (current.operatorToken.kind === ts.SyntaxKind.PlusToken) {
      return { ...merged, guaranteedRecipe: left.guaranteedRecipe || right.guaranteedRecipe };
    }
    // `&&` can omit its class and `||` can select an uninspected fallback.
    return { ...merged, guaranteedRecipe: false, opaque: true };
  }
  if (ts.isCallExpression(current)) {
    const callee = current.expression.getText();
    if (["clsx", "classnames", "cx", "cn"].includes(callee)) {
      const args = current.arguments.map((argument) =>
        analyzeClassExpression(argument, recipeClasses, resolveLocal, resolving),
      );
      const merged = mergeClassAnalyses(args);
      return {
        ...merged,
        guaranteedRecipe: args.some((argument) => argument.guaranteedRecipe),
        opaque: args.some((argument) => argument.opaque),
      };
    }
    return { tokens: new Set(), guaranteedRecipe: false, opaque: true };
  }
  if (ts.isIdentifier(current) && resolveLocal && !resolving.has(current.text)) {
    const initializer = resolveLocal(current.text);
    if (initializer) {
      const nextResolving = new Set(resolving);
      nextResolving.add(current.text);
      return analyzeClassExpression(initializer, recipeClasses, resolveLocal, nextResolving);
    }
  }
  return { tokens: new Set(), guaranteedRecipe: false, opaque: true };
}

function jsxAttribute(
  opening: ts.JsxOpeningLikeElement,
  name: string,
): ts.JsxAttribute | undefined {
  return opening.attributes.properties.find(
    (property): property is ts.JsxAttribute =>
      ts.isJsxAttribute(property) && property.name.getText() === name,
  );
}

function jsxAttributeExpression(
  opening: ts.JsxOpeningLikeElement,
  name: string,
): ts.Expression | undefined {
  const attribute = jsxAttribute(opening, name);
  if (!attribute?.initializer) return undefined;
  if (ts.isStringLiteral(attribute.initializer)) return attribute.initializer;
  if (!ts.isJsxExpression(attribute.initializer)) return undefined;
  return attribute.initializer.expression;
}

function jsxOpeningElement(
  node: ts.JsxElement | ts.JsxSelfClosingElement,
): ts.JsxOpeningLikeElement {
  return ts.isJsxElement(node) ? node.openingElement : node;
}

function jsxElementName(opening: ts.JsxOpeningLikeElement): string {
  return opening.tagName.getText();
}

function styleValueIsReadableInk(expression: ts.Expression): boolean {
  const current = unwrapTsExpression(expression);
  if (ts.isStringLiteral(current) || ts.isNoSubstitutionTemplateLiteral(current)) {
    return READABLE_INK_VALUES.has(current.text.trim());
  }
  if (ts.isConditionalExpression(current)) {
    return styleValueIsReadableInk(current.whenTrue) && styleValueIsReadableInk(current.whenFalse);
  }
  return false;
}

function stylePaintViolations(
  expression: ts.Expression | undefined,
  sourceFile: ts.SourceFile,
  direct: boolean,
): string[] {
  if (!expression) return ["missing style expression"];
  const current = unwrapTsExpression(expression);
  if (current.kind === ts.SyntaxKind.NullKeyword || current.kind === ts.SyntaxKind.Identifier && current.getText() === "undefined") {
    return [];
  }
  if (ts.isConditionalExpression(current)) {
    return [
      ...stylePaintViolations(current.whenTrue, sourceFile, direct),
      ...stylePaintViolations(current.whenFalse, sourceFile, direct),
    ];
  }
  if (ts.isBinaryExpression(current)) {
    if (current.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) {
      return stylePaintViolations(current.right, sourceFile, direct);
    }
    if (current.operatorToken.kind === ts.SyntaxKind.BarBarToken) {
      return [
        ...stylePaintViolations(current.left, sourceFile, direct),
        ...stylePaintViolations(current.right, sourceFile, direct),
      ];
    }
  }
  if (!ts.isObjectLiteralExpression(current)) {
    return [`opaque ${direct ? "button" : "descendant"} style expression`];
  }
  const violations: string[] = [];
  for (const property of current.properties) {
    if (ts.isSpreadAssignment(property) || ts.isShorthandPropertyAssignment(property)) {
      violations.push("opaque style spread or shorthand");
      continue;
    }
    if (!ts.isPropertyAssignment(property)) {
      violations.push("opaque computed style property");
      continue;
    }
    const key = property.name.getText(sourceFile).replace(/^(?:['"])(.*)(?:['"])$/, "$1");
    if (ts.isComputedPropertyName(property.name) || key.startsWith("[") || key.startsWith("--")) {
      violations.push(`unsafe style property ${key}`);
      continue;
    }
    if (INLINE_PAINT_PROPERTIES.has(key)) {
      if (!direct && key === "color" && styleValueIsReadableInk(property.initializer)) continue;
      violations.push(`unsafe ${direct ? "button" : "descendant"} style property ${key}`);
    }
  }
  return violations;
}

function descendantJsxPaintViolations(
  root: ts.JsxElement | ts.JsxSelfClosingElement,
  sourceFile: ts.SourceFile,
): string[] {
  const violations: string[] = [];
  const visit = (node: ts.Node): void => {
    if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node)) {
      const opening = jsxOpeningElement(node);
      const tagName = jsxElementName(opening);
      if (tagName === "button") return;
      const style = jsxAttributeExpression(opening, "style");
      if (style) violations.push(...stylePaintViolations(style, sourceFile, false));
      if (ts.isJsxElement(node)) node.children.forEach(visit);
      return;
    }
    if (ts.isJsxExpression(node) && node.expression) {
      node.expression.forEachChild(visit);
    }
  };
  if (ts.isJsxElement(root)) root.children.forEach(visit);
  return violations;
}

function auditButtonSource(file: string, source: string): ButtonConsumer[] {
  const sourceFile = ts.createSourceFile(
    file,
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX,
  );
  const recipeClasses = cssButtonRecipeClasses();
  const localInitializers = new Map<string, ts.Expression>();
  const collectInitializers = (node: ts.Node): void => {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer) {
      localInitializers.set(node.name.text, node.initializer);
    }
    ts.forEachChild(node, collectInitializers);
  };
  collectInitializers(sourceFile);
  const consumers: ButtonConsumer[] = [];
  const visit = (node: ts.Node): void => {
    if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node)) {
      const opening = jsxOpeningElement(node);
      if (jsxElementName(opening) === "button") {
        const line = sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1;
        const classAttribute = jsxAttribute(opening, "className");
        const classExpression = jsxAttributeExpression(opening, "className");
        const classAnalysis = analyzeClassExpression(
          classExpression,
          recipeClasses,
          (name) => localInitializers.get(name),
        );
        const violations: string[] = [];
        if (!classAttribute) violations.push("button is missing a className recipe");
        if (!classAnalysis.guaranteedRecipe) {
          violations.push("button className does not guarantee a CSS recipe");
        }
        if (opening.attributes.properties.some((property) => ts.isJsxSpreadAttribute(property))) {
          violations.push("opaque JSX button spread hides button paint");
        }
        const style = jsxAttributeExpression(opening, "style");
        if (style) violations.push(...stylePaintViolations(style, sourceFile, true));
        violations.push(...descendantJsxPaintViolations(node, sourceFile));
        consumers.push({
          tag: opening.getText(sourceFile),
          element: node.getText(sourceFile),
          file,
          classValue: classExpression?.getText(sourceFile) ?? "",
          styleValue: jsxAttribute(opening, "style")?.initializer?.getText(sourceFile) ?? null,
          astViolations: violations.map((violation) => `${file}:${line}: ${violation}`),
        });
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return consumers;
}

function buttonConsumers(): ButtonConsumer[] {
  return componentSources().flatMap(([file, source]) => auditButtonSource(file, source));
}

function buttonAuditViolations(consumer: ButtonConsumer): string[] {
  if (consumer.astViolations) return consumer.astViolations;
  const violations = spreadAttributes(consumer.tag).map(
    (spread) => `${consumer.file}: opaque JSX button spread ${spread}`,
  );
  if (
    consumer.styleValue &&
    unsafeStyleExpression(consumer.styleValue)
  ) {
    violations.push(
      `${consumer.file}: inline button paint bypasses the shared or named recipe`,
    );
  }
  return violations;
}

/**
 * CSS scanners used by these invariants. A regular-expression brace match is
 * not sufficient here: a declaration can contain a quoted `}` or `/*`, and a
 * comment can contain a complete-looking rule. Keep all boundary discovery
 * outside comments and strings, then return source slices bounded by the
 * matching brace.
 */
interface CssRule {
  selector: string;
  body: string;
}

type CssQuote = "'" | '"' | "`" | null;

function isEscaped(source: string, index: number): boolean {
  let slashes = 0;
  for (let cursor = index - 1; cursor >= 0 && source[cursor] === "\\"; cursor -= 1) {
    slashes += 1;
  }
  return slashes % 2 === 1;
}

function skipCssComment(source: string, start: number, end: number): number {
  const close = source.indexOf("*/", start + 2);
  return close < 0 ? end : close + 2;
}

function stripCssComments(source: string): string {
  let output = "";
  let quote: CssQuote = null;
  let cursor = 0;
  while (cursor < source.length) {
    const character = source[cursor]!;
    if (quote) {
      output += character;
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      cursor += 1;
      continue;
    }
    if (character === "/" && source[cursor + 1] === "*") {
      output += " ";
      cursor = skipCssComment(source, cursor, source.length);
      continue;
    }
    if (character === "'" || character === '"' || character === "`") quote = character;
    output += character;
    cursor += 1;
  }
  return output;
}

function findCssOpen(source: string, start: number, end: number): number {
  let quote: CssQuote = null;
  for (let cursor = start; cursor < end; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "/" && source[cursor + 1] === "*") {
      cursor = skipCssComment(source, cursor, end) - 1;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      continue;
    }
    if (character === "{") return cursor;
  }
  return -1;
}

function findCssClose(source: string, open: number, end = source.length): number {
  let depth = 1;
  let quote: CssQuote = null;
  for (let cursor = open + 1; cursor < end; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "/" && source[cursor + 1] === "*") {
      cursor = skipCssComment(source, cursor, end) - 1;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      if (depth === 0) return cursor;
    }
  }
  return -1;
}

function findCssMarker(source: string, marker: string): number {
  let quote: CssQuote = null;
  for (let cursor = 0; cursor < source.length; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "/" && source[cursor + 1] === "*") {
      cursor = skipCssComment(source, cursor, source.length) - 1;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      continue;
    }
    if (source.startsWith(marker, cursor)) return cursor;
  }
  return -1;
}

function cssRules(source: string): CssRule[] {
  const rules: CssRule[] = [];

  function parseRange(start: number, end: number): void {
    let cursor = start;
    while (cursor < end) {
      const open = findCssOpen(source, cursor, end);
      if (open < 0) return;
      const close = findCssClose(source, open, end);
      if (close < 0) return;

      const selector = stripCssComments(source.slice(cursor, open)).trim();
      const body = source.slice(open + 1, close);
      if (selector && !selector.startsWith("@")) rules.push({ selector, body });
      parseRange(open + 1, close);
      cursor = close + 1;
    }
  }

  parseRange(0, source.length);
  return rules;
}

function cssRuleBody(rules: CssRule[], selector: string): string {
  const exact = rules.find((candidate) => candidate.selector.trim() === selector);
  const rule = exact ?? rules.find((candidate) =>
    candidate.selector.split(",").some((part) => part.trim() === selector),
  );
  if (!rule) throw new Error(`Missing CSS rule: ${selector}`);
  return rule.body;
}

/** Return the contents of the first balanced block after a CSS marker. */
function blockAfter(source: string, marker: string): string {
  const markerStart = findCssMarker(source, marker);
  if (markerStart < 0) throw new Error(`Missing CSS marker: ${marker}`);
  const open = marker.endsWith("{")
    ? markerStart + marker.length - 1
    : findCssOpen(source, markerStart + marker.length, source.length);
  if (open < 0) throw new Error(`Missing opening brace after: ${marker}`);
  const close = findCssClose(source, open);
  if (close < 0) throw new Error(`Unclosed CSS block after: ${marker}`);
  return source.slice(open + 1, close);
}

function declarations(source: string): Record<string, string> {
  return Object.fromEntries(
    Array.from(source.matchAll(/(--[\w-]+)\s*:\s*([^;{}]+);/g), ([, name, value]) => [
      name ?? "",
      value?.trim() ?? "",
    ]),
  );
}

const themeBlocks = {
  light: blockAfter(css, ":root {"),
  dark: blockAfter(css, ':root[data-theme="dark"] {'),
  systemDark: blockAfter(
    blockAfter(css, "@media (prefers-color-scheme: dark) {"),
    ':root:not([data-theme="light"]) {',
  ),
};
const themeDeclarations = Object.fromEntries(
  Object.entries(themeBlocks).map(([name, block]) => [name, declarations(block)]),
) as Record<keyof typeof themeBlocks, Record<string, string>>;
const parsedCssRules = cssRules(css);

const THEME_TOKENS = [
  "--accent-readiness",
  "--accent-caution",
  "--accent-load",
  "--accent-force",
  "--accent-interaction",
  "--accent-info",
  "--gradient-neutral",
  "--gradient-readiness",
  "--gradient-caution",
  "--gradient-load",
  "--gradient-force",
  "--gradient-interaction",
  "--shadow-card",
  "--shadow-float",
  "--chrome-bg",
  "--chrome-border",
  "--focus-ring",
  "--primary-action",
  "--primary-action-shade",
  "--primary-action-hover",
  "--primary-action-hover-shade",
  "--primary-action-active",
  "--primary-action-active-shade",
  "--primary-action-disabled",
  "--primary-action-disabled-shade",
  "--primary-action-text",
  "--secondary-action-bg",
  "--secondary-action-bg-shade",
  "--secondary-action-bg-hover",
  "--secondary-action-bg-hover-shade",
  "--secondary-action-bg-active",
  "--secondary-action-bg-active-shade",
  "--secondary-action-bg-disabled",
  "--secondary-action-bg-disabled-shade",
  "--secondary-action-text",
  "--secondary-action-text-hover",
  "--secondary-action-text-active",
  "--secondary-action-text-disabled",
  "--secondary-action-border",
  "--secondary-action-border-hover",
  "--secondary-action-border-active",
  "--secondary-action-border-disabled",
  "--danger-action",
  "--danger-action-shade",
  "--danger-action-hover",
  "--danger-action-hover-shade",
  "--danger-action-active",
  "--danger-action-active-shade",
  "--danger-action-disabled",
  "--danger-action-disabled-shade",
  "--danger-action-text",
] as const;

type RGB = readonly [number, number, number];

function hexColor(value: string, name: string): RGB {
  const match = value.match(/^#([0-9a-f]{6})$/i);
  if (!match) throw new Error(`${name} is not a six-digit hex color: ${value}`);
  const hex = match[1]!;
  return [
    Number.parseInt(hex.slice(0, 2), 16),
    Number.parseInt(hex.slice(2, 4), 16),
    Number.parseInt(hex.slice(4, 6), 16),
  ];
}

function linearChannel(channel: number): number {
  const srgb = channel / 255;
  return srgb <= 0.03928
    ? srgb / 12.92
    : ((srgb + 0.055) / 1.055) ** 2.4;
}

function luminance(color: RGB): number {
  return (
    0.2126 * linearChannel(color[0]) +
    0.7152 * linearChannel(color[1]) +
    0.0722 * linearChannel(color[2])
  );
}

function contrastRatio(foreground: RGB, background: RGB): number {
  const foregroundLuminance = luminance(foreground);
  const backgroundLuminance = luminance(background);
  const lighter = Math.max(foregroundLuminance, backgroundLuminance);
  const darker = Math.min(foregroundLuminance, backgroundLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

function mix(a: RGB, b: RGB, amount: number): RGB {
  return [
    a[0] + (b[0] - a[0]) * amount,
    a[1] + (b[1] - a[1]) * amount,
    a[2] + (b[2] - a[2]) * amount,
  ];
}

type ThemeName = keyof typeof themeDeclarations;

function resolveThemeColor(value: string, theme: ThemeName, name: string): RGB {
  const variable = value.trim().match(/^var\(\s*(--[\w-]+)\s*\)$/)?.[1];
  if (variable) {
    const resolved = themeDeclarations[theme][variable];
    if (!resolved) throw new Error(`${name} references undefined ${variable}`);
    return resolveThemeColor(resolved, theme, `${name} ${variable}`);
  }
  return hexColor(value.trim(), `${name} in ${theme}`);
}

function objectBlock(source: string, marker: string): string {
  const markerStart = source.indexOf(marker);
  if (markerStart < 0) throw new Error(`Missing object marker: ${marker}`);
  const open = source.indexOf("{", markerStart + marker.length);
  if (open < 0) throw new Error(`Missing object opening brace: ${marker}`);
  const close = matchingJsBrace(source, open);
  if (close < 0) throw new Error(`Unclosed object: ${marker}`);
  return source.slice(open + 1, close);
}

const qualityHueBlock = objectBlock(zoneSelectionSource, "export const QUALITY_COLORS");
const qualityHues = Array.from(
  qualityHueBlock.matchAll(/:\s*["']([^"']+)["']/g),
  ([, value]) => value ?? "",
).filter(Boolean);
const directBoxChipHues = Array.from(
  component("TargetZonesCard.tsx").matchAll(/\bcolor\s*=\s*["']([^"']+)["']/g),
  ([, value]) => value ?? "",
).filter(Boolean);
const actualBoxChipHues = [...new Set(["var(--info)", ...qualityHues, ...directBoxChipHues])];

const periodHueBlock = objectBlock(component("ForceCurveCard.tsx"), "const PERIOD_COLORS");
const actualPeriodHues = Array.from(
  periodHueBlock.matchAll(/:\s*["']([^"']+)["']/g),
  ([, value]) => value ?? "",
).filter(Boolean);

describe("premium visual language contracts (#517)", () => {
  it("bounds CSS parsing around comments, strings, and neighboring rules", () => {
    const fixture = `
      /* } { .fake { } */
      .quoted::before { content: "} /* still a string */"; }
      /* { .also-fake { } */
      .next { color: red; }
    `;
    const rules = cssRules(fixture);
    expect(cssRuleBody(rules, ".quoted::before")).toContain("still a string");
    expect(cssRuleBody(rules, ".next")).toContain("color: red");
    expect(blockAfter(fixture, ".quoted::before {")).toContain(
      'content: "} /* still a string */"',
    );
  });

  it("treats opaque style expressions and unsafe paint branches conservatively", () => {
    expect(unsafeStyleExpression("{{ background: \"var(--primary-action)\" }}")).toBe(true);
    expect(unsafeStyleExpression("{condition ? { flex: 1 } : { color: \"#fff\" }}")).toBe(true);
    expect(unsafeStyleExpression("{{ ...buttonStyle, flex: 1 }}")).toBe(true);
    expect(unsafeStyleExpression("{templateStyle as CSSProperties}")).toBe(true);
    expect(unsafeStyleExpression("{{ flex: 1 } as CSSProperties}")).toBe(false);
    expect(unsafeStyleExpression("{{ flex: 1 }}")).toBe(false);
  });

  it("defines every semantic token in light, explicit dark, and system-dark themes", () => {
    for (const token of THEME_TOKENS) {
      for (const [theme, values] of Object.entries(themeDeclarations)) {
        expect(values[token], `${token} in ${theme}`).toBeDefined();
        expect(values[token], `${token} in ${theme}`).not.toBe("");
      }
    }

    expect(themeDeclarations.dark["--primary-action"]).toBe(
      themeDeclarations.systemDark["--primary-action"],
    );
    expect(css).toContain(':root[data-theme="dark"]');
    expect(css).toContain("@media (prefers-color-scheme: dark)");
  });

  it("keeps every semantic button state AA-readable across both themes and gradients", () => {
    const textByTheme = Object.fromEntries(
      Object.entries(themeDeclarations).map(([theme, values]) => [
        theme,
        {
          primary: hexColor(values["--primary-action-text"]!, `${theme} primary action text`),
          secondary: hexColor(values["--secondary-action-text"]!, `${theme} secondary action text`),
          secondaryHover: hexColor(values["--secondary-action-text-hover"]!, `${theme} secondary hover text`),
          secondaryActive: hexColor(values["--secondary-action-text-active"]!, `${theme} secondary active text`),
          secondaryDisabled: hexColor(values["--secondary-action-text-disabled"]!, `${theme} secondary disabled text`),
          danger: hexColor(values["--danger-action-text"]!, `${theme} danger action text`),
        },
      ]),
    );
    const states = {
      primary: [
        ["--primary-action", "--primary-action-shade", "primary"],
        ["--primary-action-hover", "--primary-action-hover-shade", "primary"],
        ["--primary-action-active", "--primary-action-active-shade", "primary"],
        ["--primary-action-disabled", "--primary-action-disabled-shade", "primary"],
      ],
      secondary: [
        ["--secondary-action-bg", "--secondary-action-bg-shade", "secondary"],
        ["--secondary-action-bg-hover", "--secondary-action-bg-hover-shade", "secondaryHover"],
        ["--secondary-action-bg-active", "--secondary-action-bg-active-shade", "secondaryActive"],
        ["--secondary-action-bg-disabled", "--secondary-action-bg-disabled-shade", "secondaryDisabled"],
      ],
      danger: [
        ["--danger-action", "--danger-action-shade", "danger"],
        ["--danger-action-hover", "--danger-action-hover-shade", "danger"],
        ["--danger-action-active", "--danger-action-active-shade", "danger"],
        ["--danger-action-disabled", "--danger-action-disabled-shade", "danger"],
      ],
    } as const;

    for (const [theme, values] of Object.entries(themeDeclarations)) {
      for (const [variant, variantStates] of Object.entries(states)) {
        for (const [startToken, endToken, textToken] of variantStates) {
          const start = hexColor(values[startToken]!, `${theme} ${startToken}`);
          const end = hexColor(values[endToken]!, `${theme} ${endToken}`);
          const text = textByTheme[theme]![textToken];
          for (let step = 0; step <= 100; step += 1) {
            const amount = step / 100;
            expect(
              contrastRatio(text, mix(start, end, amount)),
              `${theme} ${variant} ${startToken}/${endToken} at ${amount}`,
            ).toBeGreaterThanOrEqual(4.5);
          }
        }
      }
    }

    const cssStates = [
      [".btn-primary", "--primary-action", "--primary-action-shade", "--primary-action-text"],
      [".btn-primary:hover:not(:disabled):not([aria-disabled=\"true\"])", "--primary-action-hover", "--primary-action-hover-shade", "--primary-action-text"],
      [".btn-primary:active:not(:disabled):not([aria-disabled=\"true\"])", "--primary-action-active", "--primary-action-active-shade", "--primary-action-text"],
      [".btn-primary:disabled", "--primary-action-disabled", "--primary-action-disabled-shade", "--primary-action-text"],
      [".btn-secondary", "--secondary-action-bg", "--secondary-action-bg-shade", "--secondary-action-text"],
      [".btn-secondary:hover:not(:disabled):not([aria-disabled=\"true\"])", "--secondary-action-bg-hover", "--secondary-action-bg-hover-shade", "--secondary-action-text-hover"],
      [".btn-secondary:active:not(:disabled):not([aria-disabled=\"true\"])", "--secondary-action-bg-active", "--secondary-action-bg-active-shade", "--secondary-action-text-active"],
      [".btn-secondary:disabled", "--secondary-action-bg-disabled", "--secondary-action-bg-disabled-shade", "--secondary-action-text-disabled"],
      [".btn-danger", "--danger-action", "--danger-action-shade", "--danger-action-text"],
      [".btn-danger:hover:not(:disabled):not([aria-disabled=\"true\"])", "--danger-action-hover", "--danger-action-hover-shade", "--danger-action-text"],
      [".btn-danger:active:not(:disabled):not([aria-disabled=\"true\"])", "--danger-action-active", "--danger-action-active-shade", "--danger-action-text"],
      [".btn-danger:disabled", "--danger-action-disabled", "--danger-action-disabled-shade", "--danger-action-text"],
    ] as const;
    for (const [selector, startToken, endToken, textToken] of cssStates) {
      const body = cssRuleBody(parsedCssRules, selector.trim());
      expect(body, `${selector} background`).toContain(
        `background-image: linear-gradient(135deg, var(${startToken}), var(${endToken}))`,
      );
      expect(body, `${selector} text`).toContain(`color: var(${textToken})`);
    }
    for (const className of ["btn-primary", "btn-secondary", "btn-danger"]) {
      expect(cssRuleBody(parsedCssRules, `.${className}:disabled`)).toContain("opacity: 1;");
      expect(cssRuleBody(parsedCssRules, `.${className}:focus-visible`)).toContain(
        "outline: 2px solid var(--focus-ring);",
      );
    }
    expect(css).toContain(".btn-secondary.btn-inline");
    expect(css).toContain(".btn-danger.btn-inline");
    expect(component("PhoneWorkoutCard.tsx")).not.toContain("style={blockedReason ? { opacity: 0.5 }");
    expect(component("RoutineCard.tsx")).not.toContain("flex: 1, opacity: 0.5");
  });

  it("keeps every hue-driven selected endpoint readable in both themes", () => {
    // These are resolved from the real callers instead of a sample palette:
    // QUALITY_COLORS covers warning/danger/info/success, BoxChip has explicit
    // primary/ink-muted callers, and PERIOD_COLORS covers every chart toggle.
    expect(component("BoxChip.tsx")).toContain('color ?? "var(--info)"');
    expect(component("TargetZonesCard.tsx")).toContain("color={QUALITY_COLORS[q.id]}");
    expect(component("ForceCurveCard.tsx")).toContain("const PERIOD_COLORS");
    expect(actualBoxChipHues).toEqual(
      expect.arrayContaining([
        "var(--info)",
        "var(--danger)",
        "var(--warning)",
        "var(--success)",
        "var(--primary)",
        "var(--ink-muted)",
      ]),
    );
    expect(actualPeriodHues).toHaveLength(6);

    const recipes = [
      {
        name: "box chip",
        selector: '.box-chip[data-active="true"]',
        hover: '.box-chip[data-active="true"]:hover:not(:disabled):not([data-disabled="true"])',
        hues: actualBoxChipHues,
        percentages: [0.18, 0.26],
      },
      {
        name: "period toggle",
        selector: '.period-toggle[data-active="true"]',
        hover: '.period-toggle[data-active="true"]:hover:not(:disabled)',
        hues: actualPeriodHues,
        percentages: [0.18, 0.26],
      },
      {
        name: "preset basis",
        selector: '.preset-basis-option[data-selected="true"]',
        hover: '.preset-basis-option[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--info)"],
        percentages: [0.18, 0.26],
      },
      {
        name: "tolerance mode",
        selector: '.tolerance-mode-option[data-selected="true"]',
        hover: '.tolerance-mode-option[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--info)"],
        percentages: [0.18, 0.26],
      },
      {
        name: "static protocol mode",
        selector: '.protocol-mode-option[data-selected="true"][data-mode="static"]',
        hover: '.protocol-mode-option[data-selected="true"][data-mode="static"]:hover:not(:disabled)',
        hues: ["var(--success)"],
        percentages: [0.18, 0.26],
      },
      {
        name: "reverse-action protocol mode",
        selector: '.protocol-mode-option[data-selected="true"][data-mode="reverse_action"]',
        hover: '.protocol-mode-option[data-selected="true"][data-mode="reverse_action"]:hover:not(:disabled)',
        hues: ["var(--primary)"],
        percentages: [0.18, 0.26],
      },
      {
        name: "preset target mode",
        selector: '.preset-target-mode[data-selected="true"]',
        hover: '.preset-target-mode[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--primary)"],
        percentages: [0.18, 0.26],
      },
      {
        name: "recording tag/scope",
        selector: '.recording-tag-option[data-selected="true"]',
        hover: '.recording-tag-option[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--info)"],
        percentages: [0.14, 0.24],
      },
      {
        name: "consistency tag",
        selector: '.consistency-tag-option[data-selected="true"]',
        hover: '.consistency-tag-option[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--info)"],
        percentages: [0.14, 0.24],
      },
      {
        name: "recording side",
        selector: '.recording-side-option[data-selected="true"]',
        hover: '.recording-side-option[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--warning)"],
        percentages: [0.14, 0.24],
      },
      {
        name: "recording selection",
        selector: '.recording-select-button[aria-pressed="true"]',
        hover: '.recording-select-button[aria-pressed="true"]:hover:not(:disabled)',
        hues: ["var(--primary)"],
        percentages: [0.18, 0.26],
      },
      {
        name: "history filter",
        selector: '.filter-chip[aria-pressed="true"]',
        hover: '.filter-chip[aria-pressed="true"]:hover:not(:disabled)',
        hues: ["var(--primary)"],
        percentages: [0.16, 0.24],
      },
      {
        name: "rest target",
        selector: '.rest-target-button[data-selected="true"]',
        hover: '.rest-target-button[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--success)", "var(--danger)", "var(--primary)"],
        percentages: [0.2, 0.28],
      },
      {
        name: "zone focus",
        selector: ".zone-focus-button",
        hover: ".zone-focus-button:hover:not(:disabled)",
        hues: actualBoxChipHues,
        percentages: [0.12, 0.2, 0.24],
      },
      {
        name: "force action ready",
        selector: ".force-action-button.ready",
        hover: ".force-action-button:hover:not(:disabled)",
        hues: ["var(--success)"],
        percentages: [0.16, 0.24],
      },
      {
        name: "force action danger",
        selector: ".force-action-button.danger",
        hover: ".force-action-button.danger:hover:not(:disabled)",
        hues: ["var(--danger)"],
        percentages: [0.16, 0.24],
      },
    ] as const;

    const consumers = buttonConsumers();
    const extractedClasses = [
      "box-chip",
      "period-toggle",
      "preset-basis-option",
      "tolerance-mode-option",
      "protocol-mode-option",
      "preset-target-mode",
      "recording-tag-option",
      "recording-side-option",
      "recording-scope-option",
      "consistency-tag-option",
      "recording-select-button",
      "rest-target-button",
      "filter-chip",
      "zone-focus-button",
      "force-action-button",
    ];
    for (const className of extractedClasses) {
      expect(
        consumers.some(({ classValue }) => classValue.includes(className)),
        `no button consumer is wired to .${className}`,
      ).toBe(true);
      expect(css, `missing extracted button selector .${className}`).toMatch(
        new RegExp(`\\.${className}(?:[.:\\s,\\[{])`),
      );
    }

    for (const recipe of recipes) {
      const selectedBody = cssRuleBody(parsedCssRules, recipe.selector);
      const hoverBody = cssRuleBody(parsedCssRules, recipe.hover);
      expect(selectedBody, `${recipe.name} selected text`).toContain("color: var(--ink);");
      expect(selectedBody, `${recipe.name} selected text`).not.toMatch(/color:\s*#fff/i);
      expect(selectedBody, `${recipe.name} selected fill recipe`).toContain("background: color-mix");
      expect(hoverBody, `${recipe.name} hover text`).not.toMatch(/color:\s*#fff/i);

      for (const theme of Object.keys(themeDeclarations) as ThemeName[]) {
        const ink = resolveThemeColor("var(--ink)", theme, `${recipe.name} ink`);
        const surface = resolveThemeColor("var(--surface-1)", theme, `${recipe.name} surface`);
        for (const hue of recipe.hues) {
          const hueColor = resolveThemeColor(hue, theme, `${recipe.name} ${hue}`);
          for (const percentage of recipe.percentages) {
            expect(
              // CSS `color-mix(hue P%, surface)` weights the hue by P;
              // `mix` takes its interpolation amount from the first color.
              contrastRatio(ink, mix(surface, hueColor, percentage)),
              `${theme} ${recipe.name} ${hue} tint ${percentage}`,
            ).toBeGreaterThanOrEqual(4.5);
          }
        }
      }
    }
  });

  it("keeps every button consumer on a shared or named recipe", () => {
    const consumers = buttonConsumers();
    expect(consumers.length, "button audit must cover every component button").toBeGreaterThan(100);
    const semanticConsumers = consumers.filter(({ classValue }) =>
      /\bbtn-(?:primary|secondary|danger)\b/.test(classValue),
    );

    expect(semanticConsumers.some(({ tag }) => tag.includes("btn-primary"))).toBe(true);
    expect(semanticConsumers.some(({ tag }) => tag.includes("btn-secondary"))).toBe(true);
    expect(semanticConsumers.some(({ tag }) => tag.includes("btn-danger"))).toBe(true);

    for (const { file, tag, styleValue } of semanticConsumers) {
      expect(
        tag,
        `${file} overrides a shared semantic button with an inline paint property`,
      ).not.toMatch(/\b(?:background(?:-image|-color)?|color|border(?:-color)?)\s*:/);
      expect(
        unsafeStyleExpression(styleValue),
        `${file} uses an unsafe or opaque style expression on a semantic button`,
      ).toBe(false);
    }

    const violations = consumers.flatMap((consumer) =>
      buttonAuditViolations(consumer).map((violation) => `${violation}\n${consumer.tag}`),
    );
    expect(violations).toEqual([]);
  });

  it("uses the TypeScript AST for App and component button regressions", () => {
    const consumers = buttonConsumers();
    expect(consumers.some((consumer) => consumer.file === "src/App.tsx")).toBe(true);
    const phaseChooser = consumers.find(
      (consumer) => consumer.file === "src/App.tsx" && consumer.classValue.includes("phase-option"),
    );
    expect(phaseChooser).toBeDefined();
    expect(buttonAuditViolations(phaseChooser!)).toEqual([]);

    const fixture = auditButtonSource(
      "src/fixtures/button-audit.tsx",
      `
        const Example = ({ active, hue, buttonProps }: Props) => {
          const localClass = active ? "btn-primary" : "btn-secondary";
          return <>
            <button className={active ? "btn-primary" : "btn-secondary"}>
              <span style={{ color: hue }}>Unsafe descendant</span>
            </button>
            <button {...buttonProps}>Opaque props</button>
            <button className={getClassName()}>Unknown recipe</button>
            <button className={localClass}>Resolved local recipe</button>
          </>;
        };
      `,
    );
    expect(fixture).toHaveLength(4);
    expect(buttonAuditViolations(fixture[0]!)).toEqual([
      expect.stringContaining("unsafe descendant style property color"),
    ]);
    expect(buttonAuditViolations(fixture[1]!)).toEqual(
      expect.arrayContaining([
        expect.stringContaining("missing a className recipe"),
        expect.stringContaining("opaque JSX button spread"),
      ]),
    );
    expect(buttonAuditViolations(fixture[2]!)).toEqual([
      expect.stringContaining("does not guarantee a CSS recipe"),
    ]);
    expect(buttonAuditViolations(fixture[3]!)).toEqual([]);
  });

  it("keeps active phase chooser text readable while retaining each phase hue", () => {
    const phaseSource = readFileSync(join(SRC, "App.tsx"), "utf8");
    expect(phaseSource).not.toContain("color: p.color");
    expect(phaseSource).not.toContain("background: active ? p.bg");
    expect(phaseSource).not.toContain("border: `1px solid ${active ? p.color");

    const phaseHues = ["#2E96F0", "#DDB13A", "#E5743A", "#7B83EB"];
    for (const theme of Object.keys(themeDeclarations) as ThemeName[]) {
      const ink = resolveThemeColor("var(--ink)", theme, "phase chooser ink");
      const surface = resolveThemeColor("var(--surface-1)", theme, "phase chooser surface");
      for (const hue of phaseHues) {
        const phase = hexColor(hue, `phase hue ${hue}`);
        for (const percentage of [0.12, 0.18]) {
          expect(
            contrastRatio(ink, mix(surface, phase, percentage)),
            `${theme} phase tint ${hue} ${percentage}`,
          ).toBeGreaterThanOrEqual(4.5);
        }
      }
    }

    expect(cssRuleBody(parsedCssRules, ".phase-option")).toContain("color: var(--ink);");
    for (const phase of ["capacity", "strength", "power", "execution"]) {
      const active = cssRuleBody(parsedCssRules, `.phase-option[data-active="true"][data-phase="${phase}"]`);
      expect(active).toContain("box-shadow:");
      expect(active).not.toMatch(/color:\s*#fff/i);
    }
  });

  it("keeps runtime zone and workout accents in decoration, not low-contrast text", () => {
    const zoneSource = component("ZoneFocusCard.tsx");
    const phoneSource = component("PhoneWorkoutFullscreen.tsx");
    expect(zoneSource).not.toContain("color: QUALITY_COLORS[rec.zone]");
    expect(phoneSource).not.toContain("color: accent");
    expect(cssRuleBody(parsedCssRules, ".zone-focus-label")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".zone-focus-action")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".phone-workout-phase-label")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".workout-action-label")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".workout-action-button:hover:not(:disabled)")).toContain(
      "color-mix(in srgb, var(--workout-accent, var(--primary)) 12%",
    );
    expect(cssRuleBody(parsedCssRules, ".workout-action-button:focus-visible")).toContain(
      "outline: 2px solid var(--focus-ring);",
    );
    expect(cssRuleBody(parsedCssRules, ".zone-focus-button:active:not(:disabled)")).toContain(
      "color-mix(in srgb, var(--zone-focus-color, var(--info)) 24%",
    );
    expect(css).toContain(".zone-focus-button:disabled .zone-focus-label");

    const workoutHues = ["var(--success)", "var(--danger)", "var(--primary)"];
    for (const theme of Object.keys(themeDeclarations) as ThemeName[]) {
      const ink = resolveThemeColor("var(--ink)", theme, "workout accent ink");
      const canvas = resolveThemeColor("var(--canvas)", theme, "workout accent canvas");
      for (const hue of workoutHues) {
        const accent = resolveThemeColor(hue, theme, `workout ${hue}`);
        for (const percentage of [0.12, 0.18]) {
          expect(
            contrastRatio(ink, mix(canvas, accent, percentage)),
            `${theme} workout ${hue} tint ${percentage}`,
          ).toBeGreaterThanOrEqual(4.5);
        }
      }
    }
  });

  it("keeps BoxChip wrappers and inner buttons equal-width and tappable", () => {
    expect(component("TagSideEditor.tsx")).toMatch(/style=\{\{\s*flex:\s*1,\s*minWidth:\s*0\s*\}\}/);
    const host = cssRuleBody(parsedCssRules, ".box-chip-host");
    const inner = cssRuleBody(parsedCssRules, ".box-chip-host > .box-chip");
    expect(host).toContain("display: inline-flex;");
    expect(inner).toContain("width: 100%;");
    expect(inner).toContain("min-width: 0;");
    expect(inner).toContain("min-height: 44px;");
  });

  it("keeps System theme-color media fallbacks intact before matchMedia exists", () => {
    expect(bootstrapSource).toMatch(/choice\s*===\s*["']system["']/);
    expect(bootstrapSource).toMatch(/typeof\s+media\?\.matches\s*===\s*["']boolean["']/);
    expect(bootstrapSource).toMatch(/choice\s*!==\s*["']system["']\s*\|\|\s*systemPrefersDark\s*!==\s*null/);
    expect(indexHtml).toContain('media="(prefers-color-scheme: light)"');
    expect(indexHtml).toContain('media="(prefers-color-scheme: dark)"');
  });

  it("rejects raw paint and opaque prop-spread fixtures without class gating", () => {
    const rawDangerTag = buttonRegions(
      '<button style={{ background: "var(--danger)", color: "#fff" }}>Delete</button>',
    )[0]!;
    expect(
      buttonAuditViolations({
        ...rawDangerTag,
        file: "raw-danger.fixture.tsx",
        classValue: attributeValue(rawDangerTag.tag, "className") ?? "",
        styleValue: attributeValue(rawDangerTag.tag, "style"),
      }),
    ).toEqual([expect.stringContaining("inline button paint")]);

    const hardcodedTag = buttonRegions(
      '<button className={condition ? "btn-ghost" : "header-btn"} style={{ backgroundColor: "#ffffff", color: "#101828" }}>Raw</button>',
    )[0]!;
    expect(
      buttonAuditViolations({
        ...hardcodedTag,
        file: "hardcoded-paint.fixture.tsx",
        classValue: attributeValue(hardcodedTag.tag, "className") ?? "",
        styleValue: attributeValue(hardcodedTag.tag, "style"),
      }),
    ).toEqual([expect.stringContaining("inline button paint")]);

    const spreadTag = buttonRegions(
      '<button {...buttonProps}>Delete</button>',
    )[0]!;
    expect(
      buttonAuditViolations({
        ...spreadTag,
        file: "opaque-props.fixture.tsx",
        classValue: "",
        styleValue: null,
      }),
    ).toEqual([expect.stringContaining("opaque JSX button spread")]);

    const conditionalTag = buttonRegions(
      '<button className={danger ? "btn-danger" : "btn-ghost"} style={{ backgroundColor: "var(--surface-2)" }}>Delete</button>',
    )[0]!;
    expect(
      buttonAuditViolations({
        ...conditionalTag,
        file: "conditional-danger.fixture.tsx",
        classValue: attributeValue(conditionalTag.tag, "className") ?? "",
        styleValue: attributeValue(conditionalTag.tag, "style"),
      }),
    ).toEqual([expect.stringContaining("inline button paint")]);

    for (const property of [
      "background",
      "backgroundColor",
      "backgroundImage",
      "color",
      "border",
      "borderColor",
      "borderImage",
      "borderInline",
      "borderInlineColor",
      "borderBlock",
      "borderBlockColor",
      "opacity",
      "boxShadow",
      "all",
      "WebkitTextFillColor",
      "outline",
      "outlineColor",
      "textShadow",
      "textDecorationColor",
      "fill",
      "stroke",
      "caretColor",
      "accentColor",
      "colorScheme",
    ]) {
      expect(
        unsafeStyleExpression(`{{ ${property}: "var(--danger)" }}`),
        property,
      ).toBe(true);
    }
    expect(unsafeStyleExpression("{{ '--danger-fill': '#fff' }}")).toBe(true);
    expect(unsafeStyleExpression("{{ flex: 1, marginTop: 8 }}")).toBe(false);
  });

  it("maps Force recovery meaning to the correct action hierarchy", () => {
    const source = component("ForceView.tsx");
    const recoveryStart = source.indexOf('className="card surface-caution"');
    const recoveryEnd = source.indexOf("/* Protocols:", recoveryStart);
    expect(recoveryStart).toBeGreaterThanOrEqual(0);
    expect(recoveryEnd).toBeGreaterThan(recoveryStart);

    const recoveryButtons = buttonRegions(source.slice(recoveryStart, recoveryEnd));
    const retry = recoveryButtons.find(({ element }) => element.includes("Retry"));
    const discard = recoveryButtons.find(({ element }) => element.includes("Discard"));
    expect(retry).toBeDefined();
    expect(discard).toBeDefined();
    expect(retry!.tag).toContain('className="btn-primary btn-inline"');
    expect(retry!.tag).toContain('aria-label={retryingUnqueued ? "Retrying unsaved recordings" : "Retry unsaved recordings"}');
    expect(discard!.tag).toContain('className="btn-danger btn-inline"');
    expect(discard!.tag).toContain('aria-label="Discard unsaved recordings"');
    expect(recoveryButtons.indexOf(retry!)).toBeLessThan(recoveryButtons.indexOf(discard!));
  });

  it("defines explicit forced-colors states for every semantic button recipe", () => {
    const forcedRules = cssRules(blockAfter(css, "@media (forced-colors: active) {"));
    for (const className of ["btn-primary", "btn-secondary", "btn-danger"]) {
      const normal = cssRuleBody(forcedRules, `.${className}`);
      expect(normal).toContain("background: ButtonFace;");
      expect(normal).toContain("background-image: none;");
      expect(normal).toContain("border-color: ButtonText;");
      expect(normal).toContain("color: ButtonText;");

      const hover = cssRuleBody(
        forcedRules,
        `.${className}:hover:not(:disabled):not([aria-disabled="true"])`,
      );
      expect(hover).toContain("background: Highlight;");
      expect(hover).toContain("color: HighlightText;");

      const active = cssRuleBody(
        forcedRules,
        `.${className}:active:not(:disabled):not([aria-disabled="true"])`,
      );
      expect(active).toContain("background: Highlight;");
      expect(active).toContain("color: HighlightText;");

      const disabled = cssRuleBody(forcedRules, `.${className}:disabled`);
      expect(disabled).toContain("background: ButtonFace;");
      expect(disabled).toContain("border-color: GrayText;");
      expect(disabled).toContain("color: GrayText;");
      expect(disabled).toContain("opacity: 1;");

      expect(cssRuleBody(forcedRules, `.${className}:focus-visible`)).toContain(
        "outline: 2px solid Highlight;",
      );
    }
  });

  it("defines forced-colors states for extracted selected controls", () => {
    const forcedRules = cssRules(blockAfter(css, "@media (forced-colors: active) {"));
    const controls = [
      [
        "box chip",
        ".box-chip",
        '.box-chip[data-active="true"]',
        '.box-chip:disabled',
        '.box-chip:focus-visible',
        '.box-chip:hover:not(:disabled):not([data-disabled="true"])',
      ],
      [
        "period toggle",
        ".period-toggle",
        '.period-toggle[data-active="true"]',
        '.period-toggle[data-available="false"]',
        '.period-toggle:focus-visible',
        '.period-toggle:hover:not(:disabled)',
      ],
      [
        "preset basis",
        ".preset-basis-option",
        '.preset-basis-option[data-selected="true"]',
        ".preset-basis-option:disabled",
        ".preset-basis-option:focus-visible",
        ".preset-basis-option:hover:not(:disabled)",
      ],
      [
        "tolerance mode",
        ".tolerance-mode-option",
        '.tolerance-mode-option[data-selected="true"]',
        ".tolerance-mode-option:disabled",
        ".tolerance-mode-option:focus-visible",
        ".tolerance-mode-option:hover:not(:disabled)",
      ],
      [
        "protocol mode",
        ".protocol-mode-option",
        '.protocol-mode-option[data-selected="true"]',
        ".protocol-mode-option:disabled",
        ".protocol-mode-option:focus-visible",
        ".protocol-mode-option:hover:not(:disabled)",
      ],
      [
        "preset target",
        ".preset-target-mode",
        '.preset-target-mode[data-selected="true"]',
        ".preset-target-mode:disabled",
        ".preset-target-mode:focus-visible",
        ".preset-target-mode:hover:not(:disabled)",
      ],
      [
        "recording tag",
        ".recording-tag-option",
        '.recording-tag-option[data-selected="true"]',
        ".recording-tag-option:disabled",
        ".recording-tag-option:focus-visible",
        ".recording-tag-option:hover:not(:disabled)",
      ],
      [
        "recording side",
        ".recording-side-option",
        '.recording-side-option[data-selected="true"]',
        ".recording-side-option:disabled",
        ".recording-side-option:focus-visible",
        ".recording-side-option:hover:not(:disabled)",
      ],
      [
        "recording scope",
        ".recording-scope-option",
        '.recording-scope-option[data-selected="true"]',
        ".recording-scope-option:disabled",
        ".recording-scope-option:focus-visible",
        ".recording-scope-option:hover:not(:disabled)",
      ],
      [
        "consistency tag",
        ".consistency-tag-option",
        '.consistency-tag-option[data-selected="true"]',
        ".consistency-tag-option:disabled",
        ".consistency-tag-option:focus-visible",
        ".consistency-tag-option:hover:not(:disabled)",
      ],
      [
        "recording selection",
        ".recording-select-button",
        '.recording-select-button[aria-pressed="true"]',
        ".recording-select-button:disabled",
        ".recording-select-button:focus-visible",
        ".recording-select-button:hover:not(:disabled)",
      ],
      [
        "rest target",
        ".rest-target-button",
        '.rest-target-button[data-selected="true"]',
        ".rest-target-button:disabled",
        ".rest-target-button:focus-visible",
        ".rest-target-button:hover:not(:disabled)",
      ],
      [
        "filter chip",
        ".filter-chip",
        '.filter-chip[aria-pressed="true"]',
        ".filter-chip:disabled",
        ".filter-chip:focus-visible",
        ".filter-chip:hover:not(:disabled)",
      ],
      [
        "phase chooser",
        ".phase-option",
        '.phase-option[data-active="true"]',
        ".phase-option:disabled",
        ".phase-option:focus-visible",
        ".phase-option:hover:not(:disabled)",
      ],
    ] as const;

    for (const [name, normalSelector, selectedSelector, disabledSelector, focusSelector, hoverSelector] of controls) {
      const normal = cssRuleBody(forcedRules, normalSelector);
      expect(normal, `${name} normal background`).toContain("background: ButtonFace;");
      expect(normal, `${name} normal background image`).toContain("background-image: none;");
      expect(normal, `${name} normal text`).toContain("color: ButtonText;");

      const selected = cssRuleBody(forcedRules, selectedSelector);
      expect(selected, `${name} selected background`).toContain("background: Highlight;");
      expect(selected, `${name} selected border`).toContain("border-color: Highlight;");
      expect(selected, `${name} selected text`).toContain("color: HighlightText;");

      const disabled = cssRuleBody(forcedRules, disabledSelector);
      expect(disabled, `${name} disabled background`).toContain("background: ButtonFace;");
      expect(disabled, `${name} disabled border`).toContain("border-color: GrayText;");
      expect(disabled, `${name} disabled text`).toContain("color: GrayText;");
      expect(disabled, `${name} disabled opacity`).toContain("opacity: 1;");

      expect(cssRuleBody(forcedRules, focusSelector), `${name} focus`).toContain(
        "outline: 2px solid Highlight;",
      );
      const hover = cssRuleBody(forcedRules, hoverSelector);
      expect(hover, `${name} hover background`).toContain("background: Highlight;");
      expect(hover, `${name} hover text`).toContain("color: HighlightText;");
    }
  });

  it("keeps the zone focus control readable in forced colors, including descendants", () => {
    const forcedRules = cssRules(blockAfter(css, "@media (forced-colors: active) {"));
    const normal = cssRuleBody(forcedRules, ".zone-focus-button");
    expect(normal).toContain("background: ButtonFace;");
    expect(normal).toContain("border-color: ButtonText;");
    expect(normal).toContain("color: ButtonText;");
    const hover = cssRuleBody(forcedRules, ".zone-focus-button:hover:not(:disabled)");
    expect(hover).toContain("background: Highlight;");
    expect(hover).toContain("color: HighlightText;");
    const disabled = cssRuleBody(forcedRules, ".zone-focus-button:disabled");
    expect(disabled).toContain("border-color: GrayText;");
    expect(disabled).toContain("color: GrayText;");
    expect(cssRuleBody(forcedRules, ".zone-focus-button:focus-visible")).toContain(
      "outline: 2px solid Highlight;",
    );
    expect(css).toContain(".zone-focus-button:hover:not(:disabled) .zone-focus-label");
    expect(css).toContain(".zone-focus-button:active:not(:disabled) .zone-focus-action");
    expect(css).toContain(".workout-action-button:active:not(:disabled) .workout-action-label");
  });

  it("keeps the workout action button readable through forced-colors states", () => {
    const forcedRules = cssRules(blockAfter(css, "@media (forced-colors: active) {"));
    expect(cssRuleBody(forcedRules, ".workout-action-button")).toContain("color: ButtonText;");
    expect(cssRuleBody(forcedRules, ".workout-action-button:hover:not(:disabled)")).toContain(
      "color: HighlightText;",
    );
    expect(cssRuleBody(forcedRules, ".workout-action-button:active:not(:disabled)")).toContain(
      "background: Highlight;",
    );
    expect(cssRuleBody(forcedRules, ".workout-action-button:disabled")).toContain(
      "color: GrayText;",
    );
    expect(cssRuleBody(forcedRules, ".workout-action-button:focus-visible")).toContain(
      "outline: 2px solid Highlight;",
    );
  });

  it("keeps high-contrast light and dark selectors in the intended cascade", () => {
    const contrastStart = css.indexOf("@media (prefers-contrast: more) {");
    const systemDarkContrastStart = css.indexOf(
      "@media (prefers-contrast: more) and (prefers-color-scheme: dark) {",
    );
    expect(contrastStart).toBeGreaterThanOrEqual(0);
    expect(systemDarkContrastStart).toBeGreaterThan(contrastStart);

    const contrastBlock = blockAfter(css, "@media (prefers-contrast: more) {");
    const explicitDarkBlock = blockAfter(
      contrastBlock,
      ':root[data-theme="dark"] {',
    );
    const systemDarkBlock = blockAfter(
      blockAfter(
        css,
        "@media (prefers-contrast: more) and (prefers-color-scheme: dark) {",
      ),
      ':root:not([data-theme="light"]) {',
    );

    expect(contrastBlock).toContain(':root[data-theme="dark"]');
    expect(systemDarkBlock).toContain("--card-border: rgba(231,239,255,0.3)");
    expect(systemDarkBlock).toContain("--chrome-border: rgba(231,239,255,0.34)");
    expect(systemDarkBlock).toContain("--hairline: #52617A");
    expect(explicitDarkBlock).toContain("--hairline: #52617A");
    expect(systemDarkContrastStart).toBeGreaterThan(
      css.indexOf(':root[data-theme="dark"] {', contrastStart),
    );
  });

  it("keeps CSS custom-property references defined or explicitly local", () => {
    const definitions = new Set(
      Array.from(css.matchAll(/(--[\w-]+)\s*:/g), ([, token]) => token),
    );
    const localProperties = new Set([
      "--color", // SVG/chart colors supplied by the component at render time.
      "--box-chip-hue", // Dynamic chip hue is inherited by the shared BoxChip recipe.
      "--period-color", // Dynamic period overlay hue is inherited by the toggle recipe.
      "--workout-accent", // Fullscreen workout state hue is inherited by controls.
      "--zone-focus-color", // Recommended training zone hue is inherited by the button.
      "--pill-tint", // Glass action tint supplied by each fullscreen control.
      "--toast-accent", // Toast kind color supplied by ToastProvider.
    ]);

    for (const match of css.matchAll(/var\(\s*(--[\w-]+)/g)) {
      const token = match[1]!;
      if (token === "--t-" || localProperties.has(token)) continue;
      expect(definitions.has(token), `undefined CSS token ${token}`).toBe(true);
    }
  });

  it("wires representative tabs into the shared surface vocabulary", () => {
    const wiring: Record<string, string[]> = {
      "ReadinessCard.tsx": ["surface-readiness"],
      "Dashboard.tsx": ["surface-context", "surface-load"],
      "WorkoutView.tsx": ["surface-workout"],
      "ForceView.tsx": ["surface-force", "surface-caution"],
      "HistoryView.tsx": ["surface-history", "filter-chip"],
      "Sheet.tsx": ["premium-sheet"],
      "ThemeSection.tsx": ["theme-switcher", "theme-option"],
    };
    for (const [file, classes] of Object.entries(wiring)) {
      const source = component(file);
      for (const className of classes) {
        expect(source, `${file} missing ${className}`).toContain(className);
        expect(css, `missing CSS selector .${className}`).toMatch(
          new RegExp(`\\.${className}(?:[.:\\s,{])`),
        );
      }
    }
    expect(css).toContain(".surface-caution");
    expect(css).not.toContain(".metric-value");
  });

  it("keeps the shared material and preference contracts present", () => {
    for (const className of [
      "surface-readiness",
      "surface-caution",
      "surface-load",
      "surface-force",
      "surface-workout",
      "surface-history",
      "filter-chip",
      "phone-workout-resume",
      "force-connection-card",
      "premium-sheet",
    ]) {
      expect(css, `missing CSS selector .${className}`).toMatch(
        new RegExp(`\\.${className}(?:[.:\\s,{])`),
      );
    }
    expect(css).toContain("@media (prefers-reduced-motion: reduce)");
    expect(css).toContain("@media (prefers-contrast: more)");
    expect(css).toContain("@supports not");
  });

  it("exposes theme selection programmatically and preserves forced-colors focus", () => {
    const themeSource = component("ThemeSection.tsx");
    expect(themeSource).toContain('type="button"');
    expect(themeSource).toContain("aria-pressed={choice === o.value}");
    expect(themeSource).toContain('choice === o.value ? " selected" : ""');

    const forcedColors = blockAfter(css, "@media (forced-colors: active) {");
    expect(forcedColors).toContain(".theme-option.selected");
    expect(forcedColors).toContain("background: Highlight");
    expect(forcedColors).toContain("color: HighlightText");
    expect(forcedColors).toContain(".theme-option:focus-visible");
    expect(forcedColors).toContain("outline: 2px solid Highlight");
  });

  it("keeps the browser chrome aligned with the new canvas themes", () => {
    const themeMetas = Array.from(
      indexHtml.matchAll(/<meta\s+name="theme-color"[^>]*>/g),
      ([match]) => match,
    );
    expect(themeMetas).toHaveLength(2);
    expect(themeMetas).toContain(
      '<meta name="theme-color" media="(prefers-color-scheme: light)" content="#F2F4F8" />',
    );
    expect(themeMetas).toContain(
      '<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#0E121B" />',
    );

    expect(manifest.background_color).toBe("#F2F4F8");
    expect(manifest.theme_color).toBe("#F2F4F8");
    // `manifest: false` leaves the authoritative public manifest untouched;
    // Vite copies it verbatim to dist alongside the generated service worker.
    expect(viteConfig).toContain("VitePWA");
    expect(viteConfig).toMatch(/manifest:\s*false/);
    expect(packageScripts["verify:pwa"]).toBe("node scripts/verify-pwa-chrome.mjs");
    expect(packageScripts.build).toContain("npm run verify:pwa");
    expect(themeSource).toContain("syncThemeColorMeta");
    expect(mainSource).toContain("initializeTheme();");
    expect(component("ThemeSection.tsx")).not.toContain("querySelector('meta[name=\"theme-color\"]')");
    expect(bootstrapSource).toMatch(/localStorage/);
    expect(bootstrapSource).toMatch(/getItem\s*\(\s*["']theme["']\s*\)/);
    expect(bootstrapSource).toMatch(/matchMedia/);
    expect(bootstrapSource).toMatch(/data-theme/);
    expect(bootstrapSource).toMatch(/theme-color/);
    expect(bootstrapSource).toMatch(/not\s+all/);
    expect(indexHtml.indexOf("data-theme-bootstrap")).toBeLessThan(
      indexHtml.indexOf('<script type="module" src="/src/main.tsx">'),
    );

    const pwaThemeColors = design.match(
      /`theme-color`\s*=\s*`([^`]+)`\s*light\s*\/\s*`([^`]+)`\s*dark/,
    );
    expect(pwaThemeColors?.[1]).toBe("#F2F4F8");
    expect(pwaThemeColors?.[2]).toBe("#0E121B");
  });
});
