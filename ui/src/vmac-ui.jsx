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

export const gib = bytes => Number((bytes / 2 ** 30).toFixed(bytes % 2 ** 30 ? 2 : 0));
