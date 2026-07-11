// Matches supabase/migrations/20260711000000_initial_schema.sql.
// Regenerate with `supabase gen types typescript` once CLI/MCP access is set up.

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export interface Database {
  public: {
    Tables: {
      sessions: {
        Row: {
          id: string;
          user_id: string;
          date: string;
          type: string;
          type_label: string;
          duration_min: number;
          rpe: number;
          load: number;
          note: string;
          phase: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          date: string;
          type: string;
          type_label: string;
          duration_min: number;
          rpe: number;
          note?: string;
          phase: string;
          created_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          date?: string;
          type?: string;
          type_label?: string;
          duration_min?: number;
          rpe?: number;
          note?: string;
          phase?: string;
          created_at?: string;
        };
        Relationships: [];
      };
      user_settings: {
        Row: {
          user_id: string;
          current_phase: string;
          phase_start_date: string;
          updated_at: string;
        };
        Insert: {
          user_id?: string;
          current_phase?: string;
          phase_start_date?: string;
          updated_at?: string;
        };
        Update: {
          user_id?: string;
          current_phase?: string;
          phase_start_date?: string;
          updated_at?: string;
        };
        Relationships: [];
      };
      tindeq_recordings: {
        Row: {
          id: string;
          user_id: string;
          recorded_at: string;
          duration_ms: number;
          peak_kg: number;
          avg_kg: number;
          sample_count: number;
          note: string;
          samples: Json;
        };
        Insert: {
          id?: string;
          user_id?: string;
          recorded_at?: string;
          duration_ms: number;
          peak_kg: number;
          avg_kg: number;
          sample_count: number;
          note?: string;
          samples: Json;
        };
        Update: {
          id?: string;
          user_id?: string;
          recorded_at?: string;
          duration_ms?: number;
          peak_kg?: number;
          avg_kg?: number;
          sample_count?: number;
          note?: string;
          samples?: Json;
        };
        Relationships: [];
      };
    };
    Views: Record<string, never>;
    Functions: Record<string, never>;
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
}
