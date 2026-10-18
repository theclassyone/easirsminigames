/**
 * 3D → 2D software renderer for Roblox Studio viewport captures.
 *
 * Takes scene data (parts with corners, camera) from the Lua plugin
 * and produces a PNG via SVG rendering with sharp. Supports:
 * - Perspective projection from actual camera
 * - Backface culling and painter's algorithm depth sort
 * - Per-face directional shading
 * - Material-based visual hints (Neon glow, transparency, etc.)
 */

import sharp from "sharp";
import { writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ------------------------------------------------------------------
// Types
// ------------------------------------------------------------------

interface Vec3 {
  X: number;
  Y: number;
  Z: number;
}

interface PartData {
  Name: string;
  ClassName: string;
  Position: Vec3;
  Size: Vec3;
  Color: { R: number; G: number; B: number };
  Transparency: number;
  Corners: Vec3[]; // 8 world-space corners
  Shape: string;
  Material?: string;
}

interface CameraData {
  Position: Vec3;
  LookVector: Vec3;
  UpVector: Vec3;
  RightVector: Vec3;
  FieldOfView: number;
  ViewportSize: Vec3;
}

export interface SceneData {
  camera: CameraData;
  parts: PartData[];
  partCount: number;
  truncated: boolean;
}

// ------------------------------------------------------------------
// Vector math
// ------------------------------------------------------------------

function sub(a: Vec3, b: Vec3): Vec3 {
  return { X: a.X - b.X, Y: a.Y - b.Y, Z: a.Z - b.Z };
}

function dot(a: Vec3, b: Vec3): number {
  return a.X * b.X + a.Y * b.Y + a.Z * b.Z;
}

function normalize(v: Vec3): Vec3 {
  const len = Math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z);
  if (len < 1e-10) return { X: 0, Y: 0, Z: 0 };
  return { X: v.X / len, Y: v.Y / len, Z: v.Z / len };
}

// ------------------------------------------------------------------
// Projection
// ------------------------------------------------------------------

function viewTransform(cam: CameraData): (p: Vec3) => Vec3 {
  const right = normalize(cam.RightVector);
  const up = normalize(cam.UpVector);
  const fwd = { X: -cam.LookVector.X, Y: -cam.LookVector.Y, Z: -cam.LookVector.Z };

  return (p: Vec3) => {
    const d = sub(p, cam.Position);
    return { X: dot(d, right), Y: dot(d, up), Z: dot(d, fwd) };
  };
}

function perspectiveProject(
  p: Vec3,
  fovDeg: number,
  width: number,
  height: number
): { x: number; y: number; depth: number } | null {
  const depth = -p.Z;
  if (depth < 0.1) return null;

  const fovRad = (fovDeg * Math.PI) / 180;
  const f = 1 / Math.tan(fovRad / 2);
  const aspect = width / height;

  const nx = (p.X * f) / (depth * aspect);
  const ny = (p.Y * f) / depth;

  return {
    x: (nx * 0.5 + 0.5) * width,
    y: (0.5 - ny * 0.5) * height,
    depth,
  };
}

// ------------------------------------------------------------------
// Face extraction
// ------------------------------------------------------------------

const BOX_FACES: number[][] = [
  [4, 6, 7, 5], // +X
  [0, 2, 3, 1], // -X
  [2, 6, 7, 3], // +Y (top)
  [0, 4, 5, 1], // -Y (bottom)
  [0, 4, 6, 2], // -Z
  [1, 5, 7, 3], // +Z
];

const FACE_SHADE = [1.0, 0.7, 1.15, 0.55, 0.85, 0.8];

// Material-based adjustments
const MATERIAL_MODIFIERS: Record<string, { saturation: number; brightness: number; opacity: number }> = {
  "Enum.Material.Neon": { saturation: 1.3, brightness: 1.4, opacity: 1.0 },
  "Enum.Material.Glass": { saturation: 0.8, brightness: 1.1, opacity: 0.5 },
  "Enum.Material.ForceField": { saturation: 0.6, brightness: 1.3, opacity: 0.3 },
  "Enum.Material.SmoothPlastic": { saturation: 1.0, brightness: 1.05, opacity: 1.0 },
  "Enum.Material.Metal": { saturation: 0.7, brightness: 0.9, opacity: 1.0 },
  "Enum.Material.DiamondPlate": { saturation: 0.6, brightness: 0.85, opacity: 1.0 },
  "Enum.Material.Wood": { saturation: 1.1, brightness: 0.95, opacity: 1.0 },
  "Enum.Material.Concrete": { saturation: 0.5, brightness: 0.85, opacity: 1.0 },
  "Enum.Material.Brick": { saturation: 0.9, brightness: 0.9, opacity: 1.0 },
};

interface ProjectedFace {
  points: { x: number; y: number }[];
  depth: number;
  fillColor: string;
  opacity: number;
  isNeon: boolean;
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}

function shadeColor(r: number, g: number, b: number, factor: number, satFactor = 1.0, brightFactor = 1.0): string {
  // Apply brightness
  let rr = r * factor * brightFactor;
  let gg = g * factor * brightFactor;
  let bb = b * factor * brightFactor;

  // Apply saturation (desaturate toward gray)
  if (satFactor !== 1.0) {
    const gray = 0.299 * rr + 0.587 * gg + 0.114 * bb;
    rr = gray + (rr - gray) * satFactor;
    gg = gray + (gg - gray) * satFactor;
    bb = gray + (bb - gray) * satFactor;
  }

  return `rgb(${clamp(Math.round(rr), 0, 255)},${clamp(Math.round(gg), 0, 255)},${clamp(Math.round(bb), 0, 255)})`;
}

// ------------------------------------------------------------------
// SVG generation
// ------------------------------------------------------------------

function buildSVG(
  faces: ProjectedFace[],
  width: number,
  height: number,
): string {
  const lines: string[] = [];
  lines.push(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`
  );

  // Dark background
  lines.push(`<rect width="${width}" height="${height}" fill="#1a1a2e"/>`);

  // Grid
  lines.push(`<g stroke="#2a2a4a" stroke-width="0.5" opacity="0.4">`);
  for (let x = 0; x <= width; x += width / 10) {
    lines.push(`<line x1="${x}" y1="0" x2="${x}" y2="${height}"/>`);
  }
  for (let y = 0; y <= height; y += height / 10) {
    lines.push(`<line x1="0" y1="${y}" x2="${width}" y2="${y}"/>`);
  }
  lines.push(`</g>`);

  // Render faces back-to-front
  for (const face of faces) {
    const pts = face.points.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(" ");
    const opacity = face.opacity.toFixed(2);

    // Base color polygon
    lines.push(
      `<polygon points="${pts}" fill="${face.fillColor}" stroke="#000" stroke-width="0.5" opacity="${opacity}"/>`
    );

    // Neon glow effect
    if (face.isNeon) {
      lines.push(
        `<polygon points="${pts}" fill="${face.fillColor}" opacity="0.3" filter="blur(3px)"/>`
      );
    }
  }

  lines.push(`</svg>`);
  return lines.join("\n");
}

// ------------------------------------------------------------------
// Public API
// ------------------------------------------------------------------

export async function renderScene(scene: SceneData): Promise<{
  pngBase64: string;
  width: number;
  height: number;
  partCount: number;
  faceCount: number;
}> {
  const WIDTH = 1280;
  const HEIGHT = 720;

  const cam = scene.camera;
  const toView = viewTransform(cam);
  const fov = cam.FieldOfView || 70;

  const allFaces: ProjectedFace[] = [];

  for (const part of scene.parts) {
    if (!part.Corners || part.Corners.length !== 8) continue;

    const corners = part.Corners;
    const { R, G, B } = part.Color;
    const baseAlpha = 1 - (part.Transparency || 0);
    if (baseAlpha < 0.05) continue;

    // Material modifiers
    const mat = MATERIAL_MODIFIERS[part.Material ?? ""] ?? { saturation: 1.0, brightness: 1.0, opacity: 1.0 };
    const isNeon = part.Material === "Enum.Material.Neon";
    const faceOpacity = baseAlpha * mat.opacity;

    for (let fi = 0; fi < BOX_FACES.length; fi++) {
      const faceIndices = BOX_FACES[fi];
      const projected: { x: number; y: number }[] = [];
      let depthSum = 0;
      let allVisible = true;

      for (const ci of faceIndices) {
        const viewP = toView(corners[ci]);
        const screenP = perspectiveProject(viewP, fov, WIDTH, HEIGHT);
        if (!screenP) {
          allVisible = false;
          break;
        }
        projected.push({ x: screenP.x, y: screenP.y });
        depthSum += screenP.depth;
      }

      if (!allVisible || projected.length < 3) continue;

      // Backface culling
      const a = projected[0], b = projected[1], c = projected[2];
      const crossZ = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
      if (crossZ > 0) continue;

      allFaces.push({
        points: projected,
        depth: depthSum / faceIndices.length,
        fillColor: shadeColor(R, G, B, FACE_SHADE[fi], mat.saturation, mat.brightness),
        opacity: faceOpacity,
        isNeon,
      });
    }
  }

  // Sort back-to-front
  allFaces.sort((a, b) => b.depth - a.depth);

  const svg = buildSVG(allFaces, WIDTH, HEIGHT);

  // Rasterise SVG → PNG
  const svgBuffer = Buffer.from(svg);
  const pngBuffer = await sharp(svgBuffer).png().toBuffer();

  // Save debug screenshots to disk
  try {
    // Save next to the compiled JS (dist/), so one level up = project root
    const __dirname = dirname(fileURLToPath(import.meta.url));
    const debugDir = join(__dirname, "..", ".screenshots");
    await mkdir(debugDir, { recursive: true });
    const ts = new Date().toISOString().replace(/[:.]/g, "-");
    await writeFile(join(debugDir, `${ts}.svg`), svgBuffer);
    await writeFile(join(debugDir, `${ts}.png`), pngBuffer);
  } catch {
    // Non-fatal — debug saving is best-effort
  }

  return {
    pngBase64: pngBuffer.toString("base64"),
    width: WIDTH,
    height: HEIGHT,
    partCount: scene.parts.length,
    faceCount: allFaces.length,
  };
}
