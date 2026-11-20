import React, { useLayoutEffect, useRef, useState } from "react";

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

export function PageHeader({ title, subtitle, aside }) {
  return <header className="vm-header">
    <div className="vm-header-text">
      <h1>{title}</h1>
      {subtitle && <p>{subtitle}</p>}
    </div>
    {aside && <div className="vm-header-aside">{aside}</div>}
  </header>;
}

// A titled block of rows, in the manner of macOS System Settings.
export function Group({ title, children }) {
  return <section className="vm-group" aria-label={title}>
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

export function Toggle({ checked, onChange, label, disabled = false }) {
  return <button type="button" className="vm-toggle" role="switch" aria-checked={Boolean(checked)} aria-label={label}
    disabled={disabled} onClick={() => onChange(!checked)}><span aria-hidden="true" /></button>;
}

export { gib } from "./vmac-shell.mjs";
