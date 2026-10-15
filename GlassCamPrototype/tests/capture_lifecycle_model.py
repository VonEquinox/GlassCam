"""Terminal-result specification shared by late-delivery recipe tests.

This independent model describes commit/cancel behavior, not AVFoundation timing.
"""
from dataclasses import dataclass, field


@dataclass
class CaptureLifecycleModel:
    generation: int = 1
    next_request: int = 0
    request: tuple | None = None
    processed_photo: str | None = None
    completed_photo: str | None = None
    deliveries: dict = field(default_factory=dict)
    output_target: int | None = None

    def shutter(self, target=12):
        self.next_request += 1
        self.request = (self.generation, self.next_request)
        self.output_target = target
        self.processed_photo = self.completed_photo = None
        return self.request

    def did_process_photo(self, ticket):
        if ticket == self.request:
            self.processed_photo = "DNG"

    def did_finish_capture(self, ticket, success=True):
        if ticket == self.request:
            self.completed_photo = self.processed_photo if success else "capture_error"

    def stop(self):
        self.generation += 1
        if self.request is not None:
            value = self.completed_photo if self.completed_photo == "DNG" else "cancelled"
            self.deliveries.setdefault(self.request, []).append(value)
            self.request = None
