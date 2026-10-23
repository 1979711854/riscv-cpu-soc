`timescale 1ns / 1ps
// ============================================================================
// rgb2tmds —— RGB888 + 同步 → 4 对 TMDS 差分（1 时钟通道 + 3 数据通道）
// ----------------------------------------------------------------------------
// 红/绿/蓝各经 tmds_encoder 编码后由 outputserdes 串化；时钟通道发 TMDS 规定
// 的 10'b1111100000。c0/c1 控制字仅通道 0 使用（分别接 hs/vs），其余置 0。
// [!] vid_pdata/de/hs/vs 必须已寄存（tmds_encoder 的 din 亦按已寄存设计），
//     未寄存的组合输入会破坏编码器内部流水对齐。
// ============================================================================
`define UD #1
module rgb2tmds (
    output             tmds_clk_p,
    output             tmds_clk_n,
    output [2:0]       tmds_data_p,
    output [2:0]       tmds_data_n,
    
    input              rstn,
    
    input [23:0]       vid_pdata,
    input              vid_pvde,
    input              vid_phsync,
    input              vid_pvsync,
    input              pixelclk,
    
    input              serialclk 
);

   reg  [7:0]         pdataout[2:0];     //编码输入并行输入数据
   wire [9:0]         pdataoutraw[2:0];  //编码输出并行数据
   wire [2:0]         pvde;              //DE使能信号
   wire [2:0]         pc0;               //控制信号
   wire [2:0]         pc1;               //控制信号
   
   //DVI clock output
   outputserdes #(
       .KPARALLELWIDTH   (  10  )
   ) 
   clockserializer(
       .pixelclk         (  pixelclk        ),              
       .serialclk        (  serialclk       ),              
       .sdataout_p       (  tmds_clk_p      ),              
       .sdataout_n       (  tmds_clk_n      ),              
       .pdataout         (  10'b1111100000  ),               
       .rstn             (  rstn            )               
   );
   
   generate
       genvar  i;
       for (i = 0; i <= 2; i = i + 1)
       begin :encoder   
            //tmds encoder                           
            tmds_encoder dataencoder(
                .pix_clk     (  pixelclk       ), // pixel clock input                            
                .dout        (  pdataoutraw[i] ), // data outputs   [9:0]            
                .rstn        (  rstn           ), // async. reset input (active low)
                .din         (  pdataout[i]    ), // data inputs: expect registered [7:0]               
                .c0          (  pc0[i]         ), // c0 input                                      
                .c1          (  pc1[i]         ), // c1 input                                      
                .de          (  pvde[i]        )  // de input                                                           
            );                                      
            
            //tmds parall to serial                                    
            outputserdes #(                         
                .KPARALLELWIDTH  (  10         )    
            ) 
            dataserializer(
                .pixelclk    (  pixelclk       ),               
                .serialclk   (  serialclk      ),               
                .sdataout_p  (  tmds_data_p[i] ),                
                .sdataout_n  (  tmds_data_n[i] ),                
                .pdataout    (  pdataoutraw[i] ),               
                .rstn        (  rstn           )                
           );
       end
   endgenerate
   
   always @(*) pdataout[2] = vid_pdata[23:16];
   always @(*) pdataout[1] = vid_pdata[15:8];
   always @(*) pdataout[0] = vid_pdata[7:0];
   assign pc0[2:1] = {2{1'b0}};
   assign pc1[2:1] = {2{1'b0}};
   assign pc0[0] = vid_phsync;
   assign pc1[0] = vid_pvsync;
   assign pvde = {vid_pvde, vid_pvde, vid_pvde};
   
endmodule
