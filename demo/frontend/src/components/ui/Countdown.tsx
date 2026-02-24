"use client";

import { useEffect, useState } from "react";
import { timeUntil, timeAgo } from "@/lib/utils";

export function Countdown({ deadline }: { deadline: string }) {
  const [label, setLabel] = useState("");

  useEffect(() => {
    function update() {
      const now = Math.floor(Date.now() / 1000);
      if (Number(deadline) <= now) {
        setLabel(timeAgo(deadline));
      } else {
        setLabel(timeUntil(deadline));
      }
    }
    update();
    const interval = setInterval(update, 1000);
    return () => clearInterval(interval);
  }, [deadline]);

  const isPast = Number(deadline) <= Math.floor(Date.now() / 1000);

  return (
    <span className={`text-xs ${isPast ? "text-white/25" : "text-white/65"}`}>
      {isPast ? `Ended ${label}` : `Ends in ${label}`}
    </span>
  );
}
