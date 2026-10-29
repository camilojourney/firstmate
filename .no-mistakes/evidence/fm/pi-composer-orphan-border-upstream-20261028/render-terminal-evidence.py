"""Render actual tmux ANSI viewport captures as reviewer-visible terminal images."""
import html
import re
from pathlib import Path

ROOT = Path(__file__).parent
PALETTE = ['#000000', '#cd3131', '#0dbc79', '#e5e510', '#2472c8', '#bc3fbc', '#11a8cd', '#e5e5e5', '#666666', '#f14c4c', '#23d18b', '#f5f543', '#3b8eea', '#d670d6', '#29b8db', '#ffffff']


def color256(n):
    if n < 16:
        return PALETTE[n]
    if n >= 232:
        v = 8 + 10 * (n - 232)
        return f'#{v:02x}{v:02x}{v:02x}'
    n -= 16
    levels = [0, 95, 135, 175, 215, 255]
    return '#%02x%02x%02x' % (levels[n // 36], levels[n // 6 % 6], levels[n % 6])


def render(filename, title):
    raw = (ROOT / f'{filename}.ansi').read_text()
    body = ['<rect width="1240" height="554" fill="#181818"/>', f'<text x="20" y="28" font-size="16" fill="#ffffff">{html.escape(title)}</text>']
    foreground = '#dddddd'
    background = '#181818'
    bold = False
    reverse = False
    for y, line in enumerate(raw.splitlines()):
        x = 0
        for token in re.split(r'(\x1b\[[0-9;:]*m)', line):
            if token.startswith('\x1b['):
                params = [int(v or 0) for v in token[2:-1].replace(':', ';').split(';')]
                i = 0
                while i < len(params):
                    p = params[i]
                    if p == 0:
                        foreground, background, bold, reverse = '#dddddd', '#181818', False, False
                    elif p == 1:
                        bold = True
                    elif p == 22:
                        bold = False
                    elif p == 7:
                        reverse = True
                    elif p == 27:
                        reverse = False
                    elif p == 39:
                        foreground = '#dddddd'
                    elif p == 49:
                        background = '#181818'
                    elif 30 <= p <= 37:
                        foreground = PALETTE[p - 30]
                    elif 90 <= p <= 97:
                        foreground = PALETTE[p - 90 + 8]
                    elif 40 <= p <= 47:
                        background = PALETTE[p - 40]
                    elif p in (38, 48) and i + 2 < len(params):
                        if params[i + 1] == 5:
                            color = color256(params[i + 2])
                            i += 2
                        elif params[i + 1] == 2 and i + 4 < len(params):
                            color = '#%02x%02x%02x' % tuple(params[i + 2:i + 5])
                            i += 4
                        else:
                            i += 1
                            continue
                        if p == 38:
                            foreground = color
                        else:
                            background = color
                    i += 1
                continue
            if not token:
                continue
            fg, bg = (background, foreground) if reverse else (foreground, background)
            if bg != '#181818':
                body.append(f'<rect x="{20+x*12}" y="{47+y*20}" width="{len(token)*12}" height="20" fill="{bg}"/>')
            weight = 'bold' if bold else 'normal'
            body.append(f'<text xml:space="preserve" x="{20+x*12}" y="{63+y*20}" fill="{fg}" font-weight="{weight}">{html.escape(token)}</text>')
            x += len(token)
    svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1240" height="554" viewBox="0 0 1240 554"><g font-family="Menlo,Consolas,monospace" font-size="20">' + ''.join(body) + '</g></svg>'
    (ROOT / f'{filename}.svg').write_text(svg)


for name, title in [('idle-pi', 'Live Pi: orphan table border above an empty composer'), ('typed-pi', 'Live Pi: unsubmitted draft preserved after refused exit and relaunch'), ('border-draft-pi', 'Live Pi: border inside the composer remains unsafe, never empty')]:
    render(name, title)
