// Map inferred latches to the IHP latch cell. Used for local area estimates.
module \$_DLATCH_P_ (input E, input D, output Q);
    sg13g2_dlhq_1 _TECHMAP_REPLACE_ (.D(D), .GATE(E), .Q(Q));
endmodule
