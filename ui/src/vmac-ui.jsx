import React, { useLayoutEffect, useRef, useState } from "react";
import { ChevronRight } from "lucide-react";

// A switch is the platform's own control where the browser has one (the
// `switch` attribute); elsewhere the stylesheet draws the checkbox as one.
if (typeof HTMLInputElement !== "undefined" && !("switch" in HTMLInputElement.prototype)) {
  document.documentElement.classList.add("vm-no-switch");
}

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

export function PageHeader({ title, subtitle }) {
  return <header className="vm-header">
    <h1>{title}</h1>
    {subtitle && <p>{subtitle}</p>}
  </header>;
}

// A card of rows. `title` is shown as the card's first line; `label` only
// names the group for assistive technology, for a card that needs no heading.
export function Group({ title, label, children }) {
  return <section className="vm-group" aria-label={title || label}>
    {title && <h2 className="vm-group-title">{title}</h2>}
    <div className="vm-group-rows">{children}</div>
  </section>;
}

// One row of a group: what it is on the left, its control or value on the right.
export function Row({ title, detail, children }) {
  return <div className="vm-row">
    <div className="vm-row-text"><span>{title}</span>{detail && <small>{detail}</small>}</div>
    {children && <div className="vm-row-control">{children}</div>}
  </div>;
}

// A row that opens another page: the whole row is the button.
export function LinkRow({ icon: Icon, title, detail, children, onClick }) {
  return <button type="button" className="vm-row" onClick={onClick}>
    {Icon && <span className="vm-row-icon" aria-hidden="true"><Icon size={17} /></span>}
    <span className="vm-row-text"><span>{title}</span>{detail && <small>{detail}</small>}</span>
    {children && <span className="vm-row-control">{children}</span>}
    <ChevronRight size={16} className="vm-row-chevron" aria-hidden="true" />
  </button>;
}

export function Toggle({ checked, onChange, label, disabled = false }) {
  return <input type="checkbox" switch="" role="switch" className="vm-switch" aria-label={label}
    checked={Boolean(checked)} disabled={disabled} onChange={event => onChange(event.target.checked)} />;
}

export { gib } from "./vmac-shell.mjs";
