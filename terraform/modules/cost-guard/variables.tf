variable "max_age_minutes" {
  description = "Terminate SSITest=true instances older than this many minutes."
  type        = number
  default     = 120
}

variable "dry_run" {
  description = "If true, log what would be terminated but do not actually terminate."
  type        = bool
  default     = false
}
