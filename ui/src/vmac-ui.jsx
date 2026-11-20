import React, { useLayoutEffect, useRef, useState } from "react";
import { ChevronRight } from "lucide-react";

// A segmented control whose highlight slides to the selected option.
export function Segmented({ items, value, onChange, label, disabled = false }) {
  const group = useRef(null);
  const [thumb, setThumb] = useState(null);
  useLayoutEffect(() => {
    const node = group.current;
    if (!node) return;
    const place = () => {
      const active = node.querySelector('[aria-pressed="true"]');
      setThumb(active ? { x: active.offsetLeft, width: active.offsetWidth } : null);
    };
    place();
    const observer = new ResizeObserver(place);
    observer.observe(node);
    return () => observer.disconnect();
  }, [value, items.length]);
  return <div className="vm-seg" role="group" aria-label={label} ref={group}>
    {thumb && <span className="vm-seg-thumb" aria-hidden="true" style={{ width: thumb.width, transform: `translateX(${thumb.x}px)` }} />}
    {items.map(([id, text, badge]) => <button key={id} type="button" aria-pressed={value === id} disabled={disabled} onClick={() => onChange(id)}>
      {text}{badge !== undefined && badge !== null && <span className="vm-seg-badge">{badge}</span>}
    </button>)}
  </div>;
}

export function StatusChip({ tone = "idle", children, title }) {
  return <span className={`vm-chip ${tone}`} title={title}><i aria-hidden="true" />{children}</span>;
}

// A state in words with its dot, for use inside a line of text.
export function State({ tone = "idle", children }) {
  return <span className={`vm-state ${tone}`}><i aria-hidden="true" />{children}</span>;
}

// The top of a page: its name and what the page is for.
export function PageHeader({ title, subtitle, aside }) {
  return <header className="vm-header">
    <div>
      <h1>{title}</h1>
      {subtitle && <p>{subtitle}</p>}
    </div>
    {aside}
  </header>;
}

// A section: a heading over its rows. `label` only names the section for
// assistive technology, for one that needs no visible heading.
export function Group({ title, label, children }) {
  return <section className="vm-section" aria-label={title || label}>
    {title && <h2 className="vm-section-label">{title}</h2>}
    <div className="vm-section-body">{children}</div>
  </section>;
}

// One row of a group: what it is on the left, its control or value on the right.
export function Row({ title, detail, children }) {
  return <div className="vm-row">
    <div className="vm-row-text"><span>{title}</span>{detail && <small>{detail}</small>}</div>
    {children && <div className="vm-row-control">{children}</div>}
  </div>;
}

// A row that opens another page: the whole row is the button, and what the
// page currently says sits at the right.
export function LinkRow({ title, detail, value, onClick }) {
  return <button type="button" className="vm-row" onClick={onClick}>
    <span className="vm-row-text"><span>{title}</span>{detail && <small>{detail}</small>}</span>
    {value && <span className="vm-row-value">{value}</span>}
    <ChevronRight size={16} className="vm-row-arrow" aria-hidden="true" />
  </button>;
}

export function Toggle({ checked, onChange, label, disabled = false }) {
  return <input type="checkbox" role="switch" className="vm-switch" aria-label={label}
    checked={Boolean(checked)} disabled={disabled} onChange={event => onChange(event.target.checked)} />;
}

export { gib } from "./vmac-shell.mjs";
