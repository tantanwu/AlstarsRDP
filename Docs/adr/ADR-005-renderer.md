# ADR-005: Metal renderer with copied FreeRDP frames

Status: Accepted for correctness baseline  
Date: 2026-07-27

FreeRDP decodes into a BGRA GDI surface. The bridge copies a complete frame before returning from `EndPaint`, preventing the UI from reading mutable or freed protocol memory. `MetalFrameView` reuses a BGRA texture, preserves aspect ratio and maps input through the same fitted rectangle.

Dirty-rectangle transfer and staging-buffer reuse are planned performance optimizations. A Core Graphics fallback remains a milestone requirement and is not claimed complete.

