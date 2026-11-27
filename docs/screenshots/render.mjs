#!/usr/bin/env node
// Renders terminal output with ANSI escapes to two SVG pictures of a terminal window, one for a
// light and one for a dark page. Knows what ./deploy prints: colors, bold and dim, \r, \033[K,
// \033[J and cursor-up. No packages needed.
//
//   node docs/screenshots/render.mjs <input.ansi> <output prefix>
//
// Writes <output prefix>-light.svg and <output prefix>-dark.svg.

import { readFileSync, writeFileSync } from 'node:fs';

const THEMES = {
    light: {
        window: '#f6f8fa', border: '#d0d7de', bar: '#eaeef2', text: '#1f2328', dim: '#6e7781',
        red: '#cf222e', green: '#1a7f37', yellow: '#9a6700',
    },
    dark: {
        window: '#0d1117', border: '#30363d', bar: '#161b22', text: '#e6edf3', dim: '#8b949e',
        red: '#f85149', green: '#3fb950', yellow: '#d29922',
    },
};
const COLORS = { 31: 'red', 32: 'green', 33: 'yellow' };
const FONT_SIZE = 14;
const CHAR_WIDTH = 8.43;
const LINE_HEIGHT = 21;
const PAD = 20;
const BAR = 36;

// A screen of cells, each a character with its style.
function parse(input) {
    const lines = [[]];
    let row = 0;
    let col = 0;
    let style = { bold: false, dim: false, color: null };
    const re = /\x1b\[([?0-9;]*)([A-Za-z])|\r|\n|[\s\S]/gu;

    for (const [token, params, command] of input.matchAll(re)) {
        if (command) {
            const n = parseInt(params, 10) || 1;
            if (command === 'm') {
                for (const code of (params || '0').split(';').map(Number)) {
                    if (code === 0) style = { bold: false, dim: false, color: null };
                    else if (code === 1) style = { ...style, bold: true };
                    else if (code === 2) style = { ...style, dim: true };
                    else if (code === 22) style = { ...style, bold: false, dim: false };
                    else if (code === 39) style = { ...style, color: null };
                    else if (COLORS[code]) style = { ...style, color: COLORS[code] };
                }
            } else if (command === 'K') {
                lines[row].length = Math.min(lines[row].length, col);
            } else if (command === 'J') {
                lines[row].length = Math.min(lines[row].length, col);
                lines.length = row + 1;
            } else if (command === 'A') {
                row = Math.max(0, row - n);
            }
            continue;
        }
        if (token === '\r') {
            col = 0;
        } else if (token === '\n') {
            row++;
            col = 0;
            while (lines.length <= row) lines.push([]);
        } else {
            const line = lines[row];
            while (line.length < col) line.push({ ch: ' ', style });
            line[col++] = { ch: token, style };
        }
    }

    // No trailing blanks, and no empty lines at the end.
    for (const line of lines) {
        while (line.length && line[line.length - 1].ch === ' ') line.pop();
    }
    while (lines.length && !lines[lines.length - 1].length) lines.pop();

    return lines;
}

const escape = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// Words of one style, each placed at its own column: SVG viewers collapse spaces, and a font with
// other widths for symbols cannot push the rest of the line out of its column. Each character
// past ASCII is a word of its own.
function runs(line) {
    const out = [];
    let last = null;
    line.forEach((cell, col) => {
        const wide = cell.ch.codePointAt(0) > 0x7e;
        if (cell.ch === ' ') {
            last = null;
        } else if (last && !wide && !last.wide && last.style === cell.style) {
            last.text += cell.ch;
        } else {
            last = { col, text: cell.ch, style: cell.style, wide };
            out.push(last);
        }
    });

    return out;
}

function svg(lines, theme) {
    const t = THEMES[theme];
    const cols = Math.max(60, ...lines.map((line) => line.length));
    const width = Math.ceil(cols * CHAR_WIDTH + PAD * 2.5);
    const height = BAR + PAD + lines.length * LINE_HEIGHT + PAD - 6;
    const dots = ['#ff5f57', '#febc2e', '#28c840']
        .map((fill, i) => `<circle cx="${18 + i * 20}" cy="18" r="6" fill="${fill}"/>`).join('');
    const text = lines.map((line, i) => {
        const y = BAR + PAD + i * LINE_HEIGHT + FONT_SIZE - 2;
        return runs(line).map(({ col, text, style }) => {
            const fill = style.dim ? t.dim : style.color ? t[style.color] : t.text;
            const weight = style.bold ? ' font-weight="700"' : '';
            const x = (PAD + col * CHAR_WIDTH).toFixed(1);
            return `<text x="${x}" y="${y}" fill="${fill}"${weight}>${escape(text)}</text>`;
        }).join('');
    }).join('\n');

    return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
<rect x="0.5" y="0.5" width="${width - 1}" height="${height - 1}" rx="8" fill="${t.window}" stroke="${t.border}"/>
<path d="M0.5 ${BAR}V8.5a8 8 0 0 1 8-8H${width - 8.5}a8 8 0 0 1 8 8V${BAR}Z" fill="${t.bar}" stroke="${t.border}"/>
${dots}
<g font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace" font-size="${FONT_SIZE}" xml:space="preserve">
${text}
</g>
</svg>
`;
}

const [input, prefix] = process.argv.slice(2);
if (!input || !prefix) {
    console.error('usage: render.mjs <input.ansi> <output prefix>');
    process.exit(2);
}

const lines = parse(readFileSync(input, 'utf8'));
for (const theme of Object.keys(THEMES)) {
    writeFileSync(`${prefix}-${theme}.svg`, svg(lines, theme));
}
