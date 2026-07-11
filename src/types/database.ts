export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
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
          avg_hr: number | null
          created_at: string
          elevation_gain_m: number
          ended_at: string
          id: string
          max_hr: number | null
          raw: Json | null
          rpe_confirmed: number | null
          rpe_predicted: number | null
          session_id: string | null
          started_at: string
          user_id: string
        }
        Insert: {
          active_kcal?: number | null
          attempts_confirmed?: number
          attempts_detected?: number
          avg_hr?: number | null
          created_at?: string
          elevation_gain_m?: number
          ended_at: string
          id?: string
          max_hr?: number | null
          raw?: Json | null
          rpe_confirmed?: number | null
          rpe_predicted?: number | null
          session_id?: string | null
          started_at: string
          user_id?: string
        }
        Update: {
          active_kcal?: number | null
          attempts_confirmed?: number
          attempts_detected?: number
          avg_hr?: number | null
          created_at?: string
          elevation_gain_m?: number
          ended_at?: string
          id?: string
          max_hr?: number | null
          raw?: Json | null
          rpe_confirmed?: number | null
          rpe_predicted?: number | null
          session_id?: string | null
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
      sessions: {
        Row: {
          created_at: string
          date: string
          duration_min: number
          id: string
          load: number | null
          note: string
          phase: string
          rpe: number
          type: string
          type_label: string
          user_id: string
        }
        Insert: {
          created_at?: string
          date: string
          duration_min: number
          id?: string
          load?: number | null
          note?: string
          phase: string
          rpe: number
          type: string
          type_label: string
          user_id?: string
        }
        Update: {
          created_at?: string
          date?: string
          duration_min?: number
          id?: string
          load?: number | null
          note?: string
          phase?: string
          rpe?: number
          type?: string
          type_label?: string
          user_id?: string
        }
        Relationships: []
      }
      tindeq_recordings: {
        Row: {
          avg_kg: number
          duration_ms: number
          id: string
          note: string
          peak_kg: number
          recorded_at: string
          sample_count: number
          samples: Json
          user_id: string
        }
        Insert: {
          avg_kg: number
          duration_ms: number
          id?: string
          note?: string
          peak_kg: number
          recorded_at?: string
          sample_count: number
          samples: Json
          user_id?: string
        }
        Update: {
          avg_kg?: number
          duration_ms?: number
          id?: string
          note?: string
          peak_kg?: number
          recorded_at?: string
          sample_count?: number
          samples?: Json
          user_id?: string
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
      [_ in never]: never
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
