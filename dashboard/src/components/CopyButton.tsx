import { useEffect, useState } from 'react'

type CopyState = 'idle' | 'copied' | 'failed'

interface CopyButtonProps {
  value: string
  label: string
}

const buttonText: Record<CopyState, string> = { idle: 'Copy', copied: 'Copied', failed: 'Copy failed' }
const announcement: Record<CopyState, string> = { idle: '', copied: 'Copied to clipboard', failed: 'Copy failed' }

export function CopyButton({ value, label }: CopyButtonProps) {
  const [state, setState] = useState<CopyState>('idle')

  useEffect(() => {
    if (state === 'idle') return
    const timer = setTimeout(() => setState('idle'), 1800)
    return () => clearTimeout(timer)
  }, [state])

  async function copy() {
    try {
      await navigator.clipboard.writeText(value)
      setState('copied')
    } catch {
      // Clipboard access is missing on insecure origins and in some embedded browsers.
      setState('failed')
    }
  }

  return (
    <>
      <button type="button" className={`copy ${state}`} onClick={() => void copy()} aria-label={label}>
        {buttonText[state]}
      </button>
      <span className="sr-only" aria-live="polite">{announcement[state]}</span>
    </>
  )
}
