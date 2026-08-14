export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      climb_attempts: {
        Row: {
          avg_hr: number | null
          created_at: string
          duration_s: number
          effort_score: number | null
          elevation_gain_m: number
          id: string
          motion_intensity: number | null
          peak_hr: number | null
          source: string
          started_at: string
          user_id: string
          workout_id: string
        }
        Insert: {
          avg_hr?: number | null
          created_at?: string
          duration_s: number
          effort_score?: number | null
          elevation_gain_m: number
          id?: string
          motion_intensity?: number | null
          peak_hr?: number | null
          source?: string
          started_at: string
          user_id?: string
          workout_id: string
        }
        Update: {
          avg_hr?: number | null
          created_at?: string
          duration_s?: number
          effort_score?: number | null
          elevation_gain_m?: number
          id?: string
          motion_intensity?: number | null
          peak_hr?: number | null
          source?: string
          started_at?: string
          user_id?: string
          workout_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "climb_attempts_workout_id_fkey"
            columns: ["workout_id"]
            isOneToOne: false
            referencedRelation: "climb_workouts"
            referencedColumns: ["id"]
          },
        ]
      }
      climb_workouts: {
        Row: {
          active_kcal: number | null
          attempts_confirmed: number
          attempts_detected: number
          attempts_per_10min: number | null
          avg_hr: number | null
          created_at: string
          elevation_gain_m: number
          ended_at: string
          id: string
          max_hr: number | null
          mean_effort: number | null
          raw: Json | null
          rpe_confirmed: number | null
          rpe_predicted: number | null
          session_id: string | null
          source: string
          started_at: string
          user_id: string
        }
        Insert: {
          active_kcal?: number | null
          attempts_confirmed?: number
          attempts_detected?: number
          attempts_per_10min?: number | null
          avg_hr?: number | null
          created_at?: string
          elevation_gain_m?: number
          ended_at: string
          id?: string
          max_hr?: number | null
          mean_effort?: number | null
          raw?: Json | null
          rpe_confirmed?: number | null
          rpe_predicted?: number | null
          session_id?: string | null
          source?: string
          started_at: string
          user_id?: string
        }
        Update: {
          active_kcal?: number | null
          attempts_confirmed?: number
          attempts_detected?: number
          attempts_per_10min?: number | null
          avg_hr?: number | null
          created_at?: string
          elevation_gain_m?: number
          ended_at?: string
          id?: string
          max_hr?: number | null
          mean_effort?: number | null
          raw?: Json | null
          rpe_confirmed?: number | null
          rpe_predicted?: number | null
          session_id?: string | null
          source?: string
          started_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "climb_workouts_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      health_metrics: {
        Row: {
          body_mass_kg: number | null
          computed_at: string
          date: string
          hrv_sdnn_ms: number | null
          readiness: number | null
          resp_rate_bpm: number | null
          resting_hr: number | null
          sleep_deep_hours: number | null
          sleep_hours: number | null
          sleep_rem_hours: number | null
          user_id: string
          zone: string | null
        }
        Insert: {
          body_mass_kg?: number | null
          computed_at?: string
          date: string
          hrv_sdnn_ms?: number | null
          readiness?: number | null
          resp_rate_bpm?: number | null
          resting_hr?: number | null
          sleep_deep_hours?: number | null
          sleep_hours?: number | null
          sleep_rem_hours?: number | null
          user_id?: string
          zone?: string | null
        }
        Update: {
          body_mass_kg?: number | null
          computed_at?: string
          date?: string
          hrv_sdnn_ms?: number | null
          readiness?: number | null
          resp_rate_bpm?: number | null
          resting_hr?: number | null
          sleep_deep_hours?: number | null
          sleep_hours?: number | null
          sleep_rem_hours?: number | null
          user_id?: string
          zone?: string | null
        }
        Relationships: []
      }
      live_workouts: {
        Row: {
          active_kcal: number | null
          attempt_count: number
          climbing: boolean
          climbing_since: string | null
          elevation_gain_m: number | null
          event: string
          hr: number | null
          rest_started_at: string | null
          rest_target_s: number | null
          run_id: string
          sequence: number
          started_at: string
          status: string
          terminal: boolean
          updated_at: string
          user_id: string
          workout_id: string
        }
        Insert: {
          active_kcal?: number | null
          attempt_count?: number
          climbing?: boolean
          climbing_since?: string | null
          elevation_gain_m?: number | null
          event?: string
          hr?: number | null
          rest_started_at?: string | null
          rest_target_s?: number | null
          run_id?: string
          sequence?: number
          started_at: string
          status?: string
          terminal?: boolean
          updated_at?: string
          user_id?: string
          workout_id: string
        }
        Update: {
          active_kcal?: number | null
          attempt_count?: number
          climbing?: boolean
          climbing_since?: string | null
          elevation_gain_m?: number | null
          event?: string
          hr?: number | null
          rest_started_at?: string | null
          rest_target_s?: number | null
          run_id?: string
          sequence?: number
          started_at?: string
          status?: string
          terminal?: boolean
          updated_at?: string
          user_id?: string
          workout_id?: string
        }
        Relationships: []
      }
      phase_periods: {
        Row: {
          created_at: string
          ended_on: string | null
          id: string
          phase: string
          started_on: string
          user_id: string
        }
        Insert: {
          created_at?: string
          ended_on?: string | null
          id?: string
          phase: string
          started_on: string
          user_id?: string
        }
        Update: {
          created_at?: string
          ended_on?: string | null
          id?: string
          phase?: string
          started_on?: string
          user_id?: string
        }
        Relationships: []
      }
      routine_presets: {
        Row: {
          created_at: string
          id: string
          name: string
          steps: Json
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          name?: string
          steps: Json
          user_id?: string
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
          steps?: Json
          user_id?: string
        }
        Relationships: []
      }
      sessions: {
        Row: {
          created_at: string
          date: string
          deleted_at: string | null
          duration_min: number
          group_id: string | null
          id: string
          load: number | null
          note: string
          phase: string
          rpe: number
          rpe_confirmed: boolean
          type: string
          type_label: string
          user_id: string
          workout_source: string | null
        }
        Insert: {
          created_at?: string
          date: string
          deleted_at?: string | null
          duration_min: number
          group_id?: string | null
          id?: string
          load?: number | null
          note?: string
          phase: string
          rpe: number
          rpe_confirmed?: boolean
          type: string
          type_label: string
          user_id?: string
          workout_source?: string | null
        }
        Update: {
          created_at?: string
          date?: string
          deleted_at?: string | null
          duration_min?: number
          group_id?: string | null
          id?: string
          load?: number | null
          note?: string
          phase?: string
          rpe?: number
          rpe_confirmed?: boolean
          type?: string
          type_label?: string
          user_id?: string
          workout_source?: string | null
        }
        Relationships: []
      }
      tindeq_presets: {
        Row: {
          alternate_sides: boolean
          capacity_evidence: boolean
          cadence_out_s: number
          cadence_return_s: number
          created_at: string
          hold_s: number
          holds_s: number[] | null
          id: string
          name: string
          pct_basis: string
          pct_step: number
          prepare_s: number
          protocol_mode: string
          reps: number
          rest_reps_s: number
          rest_sets_s: number
          sets: number
          setup_note: string
          target_curve: boolean
          target_kg: number | null
          target_pct: number | null
          tolerance_mode: string
          tolerance_value: number
          user_id: string
        }
        Insert: {
          alternate_sides?: boolean
          capacity_evidence?: boolean
          cadence_out_s?: number
          cadence_return_s?: number
          created_at?: string
          hold_s: number
          holds_s?: number[] | null
          id?: string
          name?: string
          pct_basis?: string
          pct_step?: number
          prepare_s?: number
          protocol_mode?: string
          reps: number
          rest_reps_s: number
          rest_sets_s: number
          sets: number
          setup_note?: string
          target_curve?: boolean
          target_kg?: number | null
          target_pct?: number | null
          tolerance_mode?: string
          tolerance_value?: number
          user_id?: string
        }
        Update: {
          alternate_sides?: boolean
          capacity_evidence?: boolean
          cadence_out_s?: number
          cadence_return_s?: number
          created_at?: string
          hold_s?: number
          holds_s?: number[] | null
          id?: string
          name?: string
          pct_basis?: string
          pct_step?: number
          prepare_s?: number
          protocol_mode?: string
          reps?: number
          rest_reps_s?: number
          rest_sets_s?: number
          sets?: number
          setup_note?: string
          target_curve?: boolean
          target_kg?: number | null
          target_pct?: number | null
          tolerance_mode?: string
          tolerance_value?: number
          user_id?: string
        }
        Relationships: []
      }
      tindeq_recordings: {
        Row: {
          actual_duration_ms: number | null
          avg_kg: number | null
          capacity_evidence: boolean | null
          cadence_markers: Json | null
          cadence_out_s: number | null
          cadence_return_s: number | null
          completed_reps: number | null
          completion_status: string | null
          deleted_at: string | null
          duration_ms: number
          external_load_kg: number | null
          group_id: string | null
          id: string
          note: string
          outcome: string | null
          peak_kg: number | null
          planned_duration_ms: number | null
          protocol_mode: string
          protocol_run_id: string | null
          recorded_at: string
          rep_no: number | null
          sample_count: number
          samples: Json
          set_metrics: Json | null
          set_no: number | null
          setup_note: string
          side: string
          source: string
          tag: string
          target_high_kg: number | null
          target_kg: number | null
          target_low_kg: number | null
          user_id: string
          zone: string | null
        }
        Insert: {
          actual_duration_ms?: number | null
          avg_kg?: number | null
          capacity_evidence?: boolean | null
          cadence_markers?: Json | null
          cadence_out_s?: number | null
          cadence_return_s?: number | null
          completed_reps?: number | null
          completion_status?: string | null
          deleted_at?: string | null
          duration_ms: number
          external_load_kg?: number | null
          group_id?: string | null
          id?: string
          note?: string
          outcome?: string | null
          peak_kg?: number | null
          planned_duration_ms?: number | null
          protocol_mode?: string
          protocol_run_id?: string | null
          recorded_at?: string
          rep_no?: number | null
          sample_count: number
          samples: Json
          set_metrics?: Json | null
          set_no?: number | null
          setup_note?: string
          side?: string
          source?: string
          tag?: string
          target_high_kg?: number | null
          target_kg?: number | null
          target_low_kg?: number | null
          user_id?: string
          zone?: string | null
        }
        Update: {
          actual_duration_ms?: number | null
          avg_kg?: number | null
          capacity_evidence?: boolean | null
          cadence_markers?: Json | null
          cadence_out_s?: number | null
          cadence_return_s?: number | null
          completed_reps?: number | null
          completion_status?: string | null
          deleted_at?: string | null
          duration_ms?: number
          external_load_kg?: number | null
          group_id?: string | null
          id?: string
          note?: string
          outcome?: string | null
          peak_kg?: number | null
          planned_duration_ms?: number | null
          protocol_mode?: string
          protocol_run_id?: string | null
          recorded_at?: string
          rep_no?: number | null
          sample_count?: number
          samples?: Json
          set_metrics?: Json | null
          set_no?: number | null
          setup_note?: string
          side?: string
          source?: string
          tag?: string
          target_high_kg?: number | null
          target_kg?: number | null
          target_low_kg?: number | null
          user_id?: string
          zone?: string | null
        }
        Relationships: []
      }
      tindeq_tags: {
        Row: {
          cf_kg: number | null
          created_at: string
          curve_fitted_at: string | null
          curve_recording_count: number | null
          hidden: boolean
          id: string
          name: string
          reverse_cf_kg: number | null
          reverse_curve_fitted_at: string | null
          reverse_curve_recording_count: number | null
          reverse_w_prime_kgs: number | null
          side_mode: string
          user_id: string
          w_prime_kgs: number | null
        }
        Insert: {
          cf_kg?: number | null
          created_at?: string
          curve_fitted_at?: string | null
          curve_recording_count?: number | null
          hidden?: boolean
          id?: string
          name: string
          reverse_cf_kg?: number | null
          reverse_curve_fitted_at?: string | null
          reverse_curve_recording_count?: number | null
          reverse_w_prime_kgs?: number | null
          side_mode?: string
          user_id?: string
          w_prime_kgs?: number | null
        }
        Update: {
          cf_kg?: number | null
          created_at?: string
          curve_fitted_at?: string | null
          curve_recording_count?: number | null
          hidden?: boolean
          id?: string
          name?: string
          reverse_cf_kg?: number | null
          reverse_curve_fitted_at?: string | null
          reverse_curve_recording_count?: number | null
          reverse_w_prime_kgs?: number | null
          side_mode?: string
          user_id?: string
          w_prime_kgs?: number | null
        }
        Relationships: []
      }
      user_settings: {
        Row: {
          current_phase: string
          phase_start_date: string
          updated_at: string
          user_id: string
        }
        Insert: {
          current_phase?: string
          phase_start_date?: string
          updated_at?: string
          user_id?: string
        }
        Update: {
          current_phase?: string
          phase_start_date?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      create_phone_workout: {
        Args: {
          p_session_id: string
          p_workout_id: string
          p_date: string
          p_type: string
          p_type_label: string
          p_duration_min: number
          p_rpe: number
          p_note: string
          p_phase: string
          p_started_at: string
          p_ended_at: string
          p_attempts?: unknown
        }
        Returns: {
          id: string
          date: string
          type: string
          type_label: string
          duration_min: number
          rpe: number
          rpe_confirmed: boolean
          load: number
          note: string
          phase: string
          group_id: string | null
          workout_source: string | null
        }[]
      }
      delete_account: { Args: never; Returns: undefined }
      link_tindeq_recordings_to_session: {
        Args: { p_recording_ids: string[]; p_session_id: string }
        Returns: {
          duration_min: number
          group_id: string
        }[]
      }
      rename_tindeq_tag: {
        Args: { new_name: string; old_name: string }
        Returns: undefined
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {},
  },
} as const
